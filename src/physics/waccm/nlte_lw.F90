module nlte_lw

!
! interface for calculation of non-LTE heating rates
!
  use shr_kind_mod,       only: r8 => shr_kind_r8
  use spmd_utils,         only: masterproc
  use ppgrid,             only: pcols, pver
  use pmgrid,             only: plev
  use rad_constituents,   only: rad_cnst_get_gas, rad_cnst_get_info

  use nlte_fomichev,      only: nlte_fomichev_init, nlte_fomichev_calc, nocooling, o3pcooling
  use nlte_aliarms,       only: nlte_aliarms_init, nlte_aliarms_calc

  use waccm_forcing,      only: waccm_forcing_init, waccm_forcing_adv,  get_cnst
  use cam_logfile,        only: iulog

  implicit none
  private
  save

! Public interfaces
  public &
       nlte_register,      &
       nlte_init,          &
       nlte_timestep_init, &
       nlte_tend

! Private module data

! namelist variables
  logical :: nlte_use_mo              ! Determines which constituents are used from NLTE calculations
!  = .true. uses MOZART constituents
!  = .false. uses constituents from bnd dataset cftgcm

  logical :: nlte_use_aliarms = .false.
  integer :: nlte_aliarms_every_X = 0

  logical :: use_data_o3
  logical :: use_waccm_forcing = .false.

  real(r8) :: o3_mw = -huge(1.0_r8)        ! O3 molecular weight

! indexes of required constituents in model constituent array
  integer :: ico2 = -1                      ! CO2 index
  integer :: io1 = -1                       ! O index
  integer :: io2 = -1                       ! O2 index
  integer :: io3 = -1                       ! O3 index
  integer :: ih = -1                        ! H index
  integer :: ino = -1                       ! NO index
  integer :: qrlaliarms_idx = -1

! merge limits for data ozone
  integer :: nbot_mlt = huge(1)              ! bottom of pure tgcm range
  integer :: ntop_cam = huge(1)              ! bottom of merge range
  real(r8):: wt_o3_mrg(pver) = -huge(1.0_r8) ! merge weights for cam o3

!================================================================================================
contains
!================================================================================================

  subroutine nlte_register()
  use physics_buffer,   only: pbuf_add_field, dtype_r8

  call pbuf_add_field('qrlaliarms',  'global', dtype_r8, (/pcols,pver/),qrlaliarms_idx)

  end subroutine nlte_register

!================================================================================================

  subroutine nlte_init (pref_mid, max_pressure_lw, nlte_use_mo_in, nlte_limit_co2, nlte_use_aliarms_in, nlte_aliarms_every_X_in)
!
! Initialize the nlte parameterizations and tgcm forcing data, if required
!------------------------------------------------------------------------
    use constituents, only: cnst_mw, cnst_get_ind
    use physconst,    only: mwco2
    use cam_history,  only: add_default, addfld
    use mo_waccm_hrates,  only: has_hrates
    use phys_control, only: phys_getopts

    real(r8),         intent(in) :: pref_mid(plev)
    real(r8),         intent(in) :: max_pressure_lw
    logical,          intent(in) :: nlte_use_mo_in
    logical,          intent(in) :: nlte_limit_co2
    logical,          intent(in) :: nlte_use_aliarms_in
    integer,          intent(in) :: nlte_aliarms_every_X_in


    real(r8) :: o1_mw = -huge(1.0_r8)      ! O molecular weight
    real(r8) :: o2_mw = -huge(1.0_r8)      ! O2 molecular weight
    real(r8) :: co2_mw = -huge(1.0_r8)     ! CO2 molecular weight
    real(r8) :: n2_mw = -huge(1.0_r8)      ! N2 molecular weight
    real(r8) :: no_mw = -huge(1.0_r8)      ! NO molecular weight
    real(r8) :: psh(pver)                  ! pressure scale height
    real(r8) :: pshmn                      ! lower range of merge
    real(r8) :: pshmx                      ! upper range of merge
    real(r8) :: pshdd                      ! scale
    integer  :: k                          ! index
    logical  :: rad_use_data_o3
    logical  :: history_waccm
!----------------------------------------------------------------------------------------

    call phys_getopts(history_waccm_out=history_waccm)

! Set flag to use mozart (or tgcm) consituents and flag to use ALI-ARMS scheme
    nlte_use_mo          = nlte_use_mo_in
    nlte_use_aliarms     = nlte_use_aliarms_in
    nlte_aliarms_every_X = nlte_aliarms_every_X_in

    ! ask rad_constituents module whether the O3 used in the climate
    ! calculation is from data
    call rad_cnst_get_info(0, use_data_o3=rad_use_data_o3)

    ! Use data ozone if nlte_use_mo=false, or if nlte_use_mo=true and the flag to use data ozone
    ! for the interactive radiation calculation has been set to .true. in the rad_constituents module
    use_data_o3 = .false.
    if ( .not. nlte_use_mo  .or. &
         (nlte_use_mo .and. rad_use_data_o3) ) use_data_o3 = .true.

! Define merge weights for data ozone
    if (use_data_o3) then
       pshmn=7.0_r8
       pshmx=8.5_r8
       pshdd=1.0_r8

       nbot_mlt = 0
       ntop_cam = 0
       do k = 1, plev
          psh(k) = log(1e5_r8/pref_mid(k))
          if (psh(k) >= pshmx) nbot_mlt = k
          if (psh(k) >= pshmn) ntop_cam = k+1
       end do

       wt_o3_mrg(:) = 0._r8
       do k = nbot_mlt+1, ntop_cam-1
          wt_o3_mrg(k) = 1._r8 - tanh( (psh(k)-pshmn)/pshdd )
       enddo
       write(iulog,*) 'NLTE data ozone merge range is ', nbot_mlt+1, ntop_cam-1
       write(iulog,*) 'NLTE data ozone merge weights are ', wt_o3_mrg(nbot_mlt+1 : ntop_cam-1)

       call addfld ('O3MRG',(/ 'lev' /), 'A','mol/mol','merged (eUV+CAM) O3 vmr')

    end if

! Get molecular weights and constituent indexes
    if (nlte_use_mo)  then

       call cnst_get_ind( 'CO2', ico2 )
       call cnst_get_ind( 'O',   io1 )
       call cnst_get_ind( 'O2',  io2 )
       call cnst_get_ind( 'O3',  io3 )
       call cnst_get_ind( 'H',   ih  )
       call cnst_get_ind( 'NO',  ino )

       co2_mw= cnst_mw(ico2)
       o1_mw = cnst_mw(io1)
       o2_mw = cnst_mw(io2)
       o3_mw = cnst_mw(io3)
       no_mw = cnst_mw(ino)
       n2_mw = 28._r8

    else

       co2_mw = mwco2
       o1_mw  = 16._r8
       o2_mw  = 32._r8
       o3_mw  = 48._r8
       no_mw  = 30._r8
       n2_mw  = 28._r8

    end if

    use_waccm_forcing = use_data_o3 .or. (.not.nlte_use_mo) .or. (.not. has_hrates)

! Initialize Fomichev parameterization
    call nlte_fomichev_init (co2_mw, n2_mw, o1_mw, o2_mw, o3_mw, no_mw, nlte_limit_co2)

! Initialize ALI-ARMS parameterization
    if (nlte_use_aliarms) then
       call nlte_aliarms_init (max_pressure_lw,co2_mw,n2_mw,o1_mw,o2_mw)
    end if

! Initialize waccm forcing data
    if (use_waccm_forcing) then
       call waccm_forcing_init ()
    endif

    if (masterproc) then

       if (nlte_use_mo) then
          write(iulog,*) 'NLTE constituents are obtained from the MOZART chemistry module'
       else
          write(iulog,*) 'NLTE constituents are obtained from boundary dataset'
       endif
    end if

    call addfld ('QRLNLTE',(/ 'lev' /), 'A','K/s','Non-LTE LW heating (includes QNO and QO3P)')
    call addfld ('QNO',    (/ 'lev' /), 'A','K/s','NO cooling')
    call addfld ('QCO2',   (/ 'lev' /), 'A','K/s','CO2 cooling')
    call addfld ('QO3',    (/ 'lev' /), 'A','K/s','O3 cooling')
    call addfld ('QHC2S',  (/ 'lev' /), 'A','K/s','Cooling to Space')
    call addfld ('QO3P',   (/ 'lev' /), 'A','K/s','O3P cooling')

! add output to default output for primary history tapes
    if (history_waccm) then
       call add_default ('QRLNLTE', 1, ' ')
       call add_default ('QNO ', 1, ' ')
       call add_default ('QCO2', 1, ' ')
       call add_default ('QO3',  1, ' ')
       call add_default ('QHC2S',1, ' ')
       call add_default ('QO3P ', 1, ' ')
    end if

  end subroutine nlte_init

!=======================================================================

  subroutine nlte_timestep_init(state, pbuf2d)
    use physics_types,  only: physics_state
    use ppgrid,         only: begchunk, endchunk
    use physics_buffer, only: physics_buffer_desc

!
! Time interpolation of waccm forcing fields to the current time
!
!------------------------------------------------------------------------

    type(physics_state), intent(in):: state(begchunk:endchunk)
    type(physics_buffer_desc), pointer :: pbuf2d(:,:)


!---------------------------Local workspace--------------------------------------

    if (use_waccm_forcing) then
       call waccm_forcing_adv (state, pbuf2d)
    endif

    return
  end subroutine nlte_timestep_init

!================================================================================================
!================================================================================================

  subroutine nlte_tend(state, pbuf, qrlf)
!
! Driver for nlte calculations
!-------------------------------------------------------------------------
    use physconst,       only: mwdry
    use air_composition, only: cpairv
    use physics_types, only: physics_state
    use physics_buffer, only : physics_buffer_desc
    use perf_mod,      only: t_startf, t_stopf
    use cam_history,   only: outfld
    use physics_buffer,only: pbuf_get_field
    use time_manager,  only: get_nstep

! Arguments
    type(physics_state), target, intent(in)  :: state   ! Physics state variables

    type(physics_buffer_desc), pointer :: pbuf(:)

    real(r8), intent(out) :: qrlf(pcols,pver)   ! nlte longwave heating rate

! Local workspace for waccm
    integer :: lchnk              ! chunk identifier
    integer :: ncol               ! no. of columns in chunk

    real(r8) :: nocool (pcols,pver)  ! NO cooling (K/s)
    real(r8) :: o3pcool (pcols,pver) ! O3P cooling (K/s)
    real(r8) :: qout (pcols,pver)    ! temp for outfld
    real(r8) :: co2cool(pcols,pver), o3cool(pcols,pver), c2scool(pcols,pver) ! (K/s)

    real(r8), pointer :: qrlaliarms(:,:) ! ALI-ARMS NLTE CO2 cooling rate (K/s)

    real(r8) :: qrlfomichev(pcols,pver) ! Fomichev cooling rate ! (K/s)

    real(r8), pointer, dimension(:,:) :: xco2mmr  ! CO2 mmr
    real(r8), pointer, dimension(:,:) :: xommr    ! O   mmr
    real(r8), pointer, dimension(:,:) :: xo2mmr   ! O2  mmr
    real(r8), pointer, dimension(:,:) :: xo3mmr   ! O3  mmr
    real(r8), pointer, dimension(:,:) :: xhmmr    ! H  mmr
    real(r8), pointer, dimension(:,:) :: xnommr   ! NO mmr
    real(r8), pointer, dimension(:,:) :: xn2mmr   ! N2  mmr

    real(r8), target :: n2mmr (pcols,pver)   ! N2  mmr
    real(r8), target :: o3mrg(pcols,pver)    ! merged O3
    real(r8), pointer, dimension(:,:) :: to3mmr  ! O3 mmr   (tgcm)

    integer :: k
    integer :: nstep

!------------------------------------------------------------------------

    lchnk = state%lchnk
    ncol  = state%ncol

! Get radiatively active ozone
    call rad_cnst_get_gas(0, 'O3', state, pbuf,  xo3mmr)
    if (use_data_o3) then
       call get_cnst (lchnk, o3=to3mmr)
       call merge_o3 (ncol, xo3mmr, to3mmr, o3mrg)
       qout(:ncol,:) = o3mrg(:ncol,:)*mwdry/o3_mw
       call outfld ('O3MRG', qout, pcols,lchnk)
       xo3mmr => o3mrg(:,:)
    end if

    if (nlte_use_mo) then

! Get relevant constituents from the chemistry module
       xco2mmr => state%q(:,:,ico2)
       xommr   => state%q(:,:,io1)
       xo2mmr  => state%q(:,:,io2)
       xhmmr   => state%q(:,:,ih)
       xnommr  => state%q(:,:,ino)

    else

       call get_cnst (lchnk, co2=xco2mmr, o1=xommr, o2=xo2mmr, no=xnommr, h=xhmmr)

    endif

    do k = 1,pver
       n2mmr (:ncol,k) = 1._r8 - (xommr(:ncol,k) + xo2mmr(:ncol,k) + xhmmr(:ncol,k))
    enddo
    xn2mmr  => n2mmr(:,:)

! do non-LTE cooling rate calculations

    call t_startf('nlte_fomichev_calc')
    call nlte_fomichev_calc (lchnk,ncol,state%pmid,state%pint,state%t, &
         xo2mmr,xommr,xo3mmr,xn2mmr,xco2mmr,qrlfomichev,co2cool,o3cool,c2scool)
    call t_stopf('nlte_fomichev_calc')


 !  Call the optional ALI-ARMS.  Note that this does not replace the fomichev
 !  call as the other individual cooling rates from fomichev still need to be calculated

    if (nlte_use_aliarms) then

       call t_startf('nlte_aliarms_calc')

       call pbuf_get_field(pbuf, qrlaliarms_idx, qrlaliarms )
       ! Only run ALI-ARMS every nlte_aliarms_every_X timesteps
       nstep = get_nstep()
       if (MOD(nstep, nlte_aliarms_every_X) == 0) then
          call nlte_aliarms_calc (lchnk,ncol,state%zm, state%pmid,state%t,xo2mmr,xommr,xn2mmr,xco2mmr,qrlaliarms)
       end if

       ! Apply the ALI-ARMS heating rate to the qrlf summation
       qrlf(:ncol,:) = o3cool(:ncol,:) + qrlaliarms(:ncol,:) * cpairv(:ncol,:,lchnk)

       call t_stopf('nlte_aliarms_calc')

    else
       qrlf(:ncol,:) = qrlfomichev(:ncol,:)
    end if


! do NO cooling
    call nocooling (ncol, state%t, state%pmid, xnommr,xommr,xo2mmr,xo3mmr,xn2mmr,nocool)

! do O3P cooling
    call o3pcooling (ncol, state%t, xommr, o3pcool)

    do k = 1,pver
       qrlf(:ncol,k) = qrlf(:ncol,k) + nocool(:ncol,k) + o3pcool(:ncol,k)
    end do

    qout(:ncol,:) = nocool(:ncol,:)/cpairv(:ncol,:,lchnk)
    call outfld ('QNO'    , qout, pcols, lchnk)
    qout(:ncol,:) = o3pcool(:ncol,:)/cpairv(:ncol,:,lchnk)
    call outfld ('QO3P'    , qout, pcols, lchnk)
    qout(:ncol,:) = qrlf(:ncol,:)/cpairv(:ncol,:,lchnk)
    call outfld ('QRLNLTE', qout, pcols, lchnk)

    qout(:ncol,:) = co2cool(:ncol,:)/cpairv(:ncol,:,lchnk)
    call outfld ('QCO2', qout, pcols, lchnk)
    qout(:ncol,:) = o3cool(:ncol,:)/cpairv(:ncol,:,lchnk)
    call outfld ('QO3', qout, pcols, lchnk)
    qout(:ncol,:) = c2scool(:ncol,:)/cpairv(:ncol,:,lchnk)
    call outfld ('QHC2S', qout, pcols, lchnk)

  end subroutine nlte_tend

!======================================================================================

  subroutine merge_o3 (ncol, o3cam, o3mlt, o3mrg)
!
! Merges CAM O3 (usually climatology) with mesosphere/lower thermosphere O3 (usually TIME/GCM)
!
!------------------Input arguments----------------------------------------------

    integer,  intent(in)    :: ncol                  ! number of atmospheric columns
    real(r8), intent(in)    :: o3mlt(pcols,pver)     ! MLT O3 mmr
    real(r8), intent(in)    :: o3cam(pcols,pver)     ! CAM O3 mmr
    real(r8), intent(out)   :: o3mrg(pcols,pver)     ! merged product

!---------------------------Local Workspace--------------------------------------------

    integer k                                        ! index

!-------------------------------------------------------------------------------------

! combine ozone profiles of TIME/GCM with CAM

! load TIME/GCM above NBOT_MLT
    do k = 1, nbot_mlt
       o3mrg(:ncol,k) = o3mlt(:ncol,k)
    end do

! merge
    do k=nbot_mlt+1,ntop_cam-1
       o3mrg(:ncol,k) = (1._r8 - wt_o3_mrg(k)) * o3cam(:ncol,k) + wt_o3_mrg(k) * o3mlt(:ncol,k)
    end do

! load CAM below NTOP_CAM
    do k=ntop_cam,pver
       o3mrg(:ncol,k) = o3cam(:ncol,k)
    end do

  end subroutine merge_o3

end module nlte_lw
