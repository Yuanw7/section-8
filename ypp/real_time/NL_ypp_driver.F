!
! License-Identifier: GPL
!
! Copyright (C) 2016 The Yambo Team
!
! Authors (see AUTHORS file for details): MG CA
!
subroutine NL_ypp_driver(en,k)
 !
 use YPP_real_time,  ONLY:X_order,RT_conf,RT_time,Pol,l_skip_OBS_IO,Pump_path
 use pars,           ONLY:SP,pi,lchlen
 use units,          ONLY:HA2EV,AUT2FS
 use R_lattice,      ONLY:bz_samp
 use electrons,      ONLY:levels
 use parser_m,       ONLY:parser
 use nl_optics,      ONLY:n_frequencies,NL_P_t
 use fields,         ONLY:Efield,EtoT,Divide_by_Field,ext_field,Efield_duplicate,Efield_strength
 use IO_int,         ONLY:io_control
 use IO_m,           ONLY:OP_RD_CL,DUMP,NONE
 use com,            ONLY:jobstr,msg
 use real_time,      ONLY:NE_steps,RT_step,NE_steps
 use stderr,         ONLY:intc,real2ch
 use RT_control,     ONLY:OBS_RT_IO_t
 use LIVE_t,         ONLY:live_timing
 !
#include<memory.h>
 !
 type(levels)  :: en
 type(bz_samp) :: k
 !
 ! Working Space
 !
 integer, external::io_NL
 integer  :: io_Nonlinear,io_Nonlinear_REF,ID,ID_REF,i_Probe
 integer  :: i_f,i_d,i_order
 character(9) :: dbname
 real(SP) :: W_step,T_period,time_range_save(2)
 real(SP),    allocatable  :: RT_P_probe(:,:,:),Harmonic_Frequency(:,:),Probe_frequency(:)
 complex(SP), allocatable  :: X_effective(:,:,:),Susceptibility(:,:,:)
 logical  :: Probe_consistency_error,l_print_pwr_spectrum
 type(ext_field)   :: Efield_probe
 logical, allocatable :: runs_ok(:)
 character(lchlen) :: jobstr_save
 !
 call section("*",'NL Post Processing')
 !
 dbname="Nonlinear"
 !
 call RT_output_INIT( )
 !
 call parser('PrtPwrSpec',l_print_pwr_spectrum)
 !
 ! Input/Output
 !
 call io_control(ACTION=OP_RD_CL,COM=NONE,SEC=(/1/),MODE=DUMP,ID=ID)
 io_Nonlinear=io_NL(dbname,ID)
 if(io_Nonlinear/=0) call error(" Error reading NonLinear database")
 !
 io_Nonlinear_REF=-1
 if(Pump_path/='none') then
    jobstr_save=jobstr
    jobstr     =trim(Pump_path)
    call io_control(ACTION=OP_RD_CL,COM=NONE,SEC=(/1/),MODE=DUMP,ID=ID_REF)
    io_Nonlinear_REF=io_NL(dbname,ID_REF)
    if(io_Nonlinear_REF/=0) call error(' Pump reference polarization not found!!')
    call msg('rs','Found Pump reference polarization in: '//Pump_path)
    jobstr     =jobstr_save
 endif 
 !
 l_skip_OBS_IO=.false.
 !
 YAMBO_ALLOC(RT_P_probe,(NE_steps,n_frequencies,3))
 YAMBO_ALLOC(Probe_frequency,(n_frequencies))
 RT_P_probe=0._SP
 Probe_frequency=0._SP
 !
 ! Reads the polarization from dbs containing simulation at different frequencies 
 !
 Probe_consistency_error=.FALSE.
 i_Probe=1
 !
 allocate(runs_ok(n_frequencies))
 runs_ok=.true.
 !
 do i_f=1,n_frequencies
   call io_control(ACTION=OP_RD_CL,COM=NONE,SEC=(/1+i_f/),MODE=DUMP,ID=ID)
   io_Nonlinear=io_NL(dbname,ID)
   !
   if(io_Nonlinear/=0) then
     runs_ok(i_f)=.false.
     cycle
   endif
   !
   Efield(i_Probe)%amplitude=Efield_strength(Efield(i_Probe)%intensity,'AU')
   !
   if (i_f==1) then
     call Efield_duplicate(Efield(i_Probe),Efield_probe)
   else
     if (Efield_probe%t_initial/=Efield(i_Probe)%t_initial)   Probe_consistency_error=.TRUE.
     if (Efield_probe%ef_name  /=Efield(i_Probe)%ef_name)     Probe_consistency_error=.TRUE.
     if ( any( (/abs(Efield_probe%FWHM  -Efield(i_Probe)%FWHM)>1.E-5,&
&                abs(Efield_probe%intensity-Efield(i_Probe)%intensity)>1.E-5/))) Probe_consistency_error=.TRUE.
   endif
   !
   do i_d=1,3
     RT_P_probe(:,i_f,i_d)=NL_P_t(:,i_d)
   enddo
   !
   Probe_frequency(i_f)=Efield(i_Probe)%frequency(1)
   !
   if(io_Nonlinear_REF==0) then
     call warning("removing reference polarization/current")
     jobstr_save=jobstr
     jobstr     =trim(PUMP_path)
     call io_control(ACTION=OP_RD_CL,COM=NONE,SEC=(/1+i_f/),MODE=DUMP,ID=ID_REF)
     io_Nonlinear=io_NL(dbname,ID_REF)
     jobstr=jobstr_save
     do i_d=1,3
       RT_P_probe(:,i_f,i_d)=RT_P_probe(:,i_f,i_d)-NL_P_t(:,i_d)
     enddo
      ! Restore original parameters of the Probe
      call Efield_duplicate(Efield_probe,Efield(i_Probe))
   endif

   !
 enddo
 !
 if (Probe_consistency_error) call error(' Not all probes have consistent parameters')
 if (any(runs_ok.eqv..false.)) call warning(' Incomplete runs')
 if (all(runs_ok.eqv..false.)) call error(' Error reading non-linear databases!')
 !
 ! Time Initialization
 !
 W_step   =minval(Probe_frequency) ! smaller frequency
 T_period =EtoT(W_step)            ! largest period
 !
 ! Special case for monochromatic source and no user input set:
 !
 if (any((/trim(Efield_probe%ef_name) == 'SIN', trim(Efield_probe%ef_name) == 'SOFTSIN', &
&          trim(Efield_probe%ef_name) == 'ANTIRES'/)).and.RT_conf%T_range(1)<0._SP) then
    RT_conf%T_range(1) = OBS_RT_IO_t%Time(OBS_RT_IO_t%N)-T_period
 endif
 !
 call RT_time_configuration_setup('POLARIZATION',OBS_RT_IO_t)
 !
 ! Check if total simulation time is long enough for analysis  
 !
 if((RT_conf%T_range(2) - RT_conf%T_range(1))<T_period) &
&   call warning('Simulation time not long enough. Period is'//trim(real2ch(T_period*AUT2FS))//' fs')
 !
 call msg('s','Field type    ', trim(Efield_probe%ef_name))
 !
 select case (trim(Efield_probe%ef_name))
   !
   ! CONTINUOUS MONOCHROMATIC SOURCES
   !
   case('SIN','SOFTSIN','ANTIRES')
     !  
     YAMBO_ALLOC(X_effective,(0:X_order,n_frequencies,3))
     YAMBO_ALLOC(Susceptibility,(0:X_order,n_frequencies,3))
     YAMBO_ALLOC(Harmonic_Frequency,(0:X_order,n_frequencies))
     !
     do i_order=0,X_order
       Harmonic_Frequency(i_order,:)=real(i_order,SP)*Probe_Frequency(:)
     enddo
     !
     call msg('s',' Harmonic frequencies        ',(/minval(Harmonic_Frequency),maxval(Harmonic_Frequency)/)*HA2EV,"[eV]")
     !
     ! Find the Fourier coefficients by inversion
     !
     call msg('s','[RT] Effective max time period     ',T_period*AUT2FS,"[fs]")
     !
     call live_timing('X effective ', n_frequencies)
     !
     time_range_save=RT_conf%T_range
     !
     do i_f = 1, n_frequencies
       !
       if(.not.runs_ok(i_f)) cycle
       !
       T_period=T_range_nl(1,i_f)
       !
       do i_d = 1,3
         call RT_coefficients_Inversion(X_order+1,X_order+1,RT_P_probe(:,i_f,i_d),X_effective(0:,i_f,i_d),&
&                                     Harmonic_Frequency(0:,i_f),T_period)
       end do
       !
       call live_timing(steps=1)
       !
     enddo
     !
     call live_timing()
     !
     RT_conf%T_range=time_range_save
     !
     ! Calculate Susceptibilities from X_effective
     !
     do i_order=0,X_order
       !
       do i_f=1,n_frequencies
         !
         if(.not.runs_ok(i_f)) cycle
         !
         if (i_order==1) then
           Susceptibility(i_order,i_f,1)=4._SP*pi*dot_product( Efield(i_Probe)%versor(:),X_effective(i_order,i_f,:) )*&
&                                        Divide_by_Field(Efield(i_Probe),i_order)
         else 
           Susceptibility(i_order,i_f,:)=X_effective(i_order,i_f,:)*Divide_by_Field(Efield(i_Probe),i_order)
         end if
         !
       enddo
       ! 
     enddo
     !
     ! Plot
     !
     call plot_X_effective()
     YAMBO_FREE(X_effective)
     YAMBO_FREE(Susceptibility)
     YAMBO_FREE(Harmonic_Frequency)
     !
   case ('DELTA','PULSE')
     !
     allocate(Pol(1))
     YAMBO_ALLOC(Pol(1)%F_t,(RT_conf%T_n_steps,3))
     Pol(1)%F_t(:,:) =RT_P_probe(:,i_Probe,:)
     Pol(1)%N=3
     Pol(1)%title="polarization"
     call RT_OBSERVABLES_damp_and_write(Pol(1),RT_conf,.FALSE.)
     call RT_X_LRR_real_field(en)
     YAMBO_FREE(Pol(1)%F_t)
     deallocate(Pol)
     !
  case default 
     ! OTHER CASES NOT YET WORKING
     !
     call error('Analysis not available for the '//trim((Efield_probe%ef_name))//' field')
 end select
 !
 YAMBO_FREE(RT_P_probe)
 !
 contains
   !
   subroutine plot_X_effective()
     !
     ! ... ordering and frequency step (defines the P(t) periodicity)
     !
     use pars,           ONLY:SP,lchlen,schlen
     use units,          ONLY:HA2EV,SVCMm12VMm1,AU2VMm1
     use YPP_real_time,  ONLY:max_n_of_paths
     use RT_control,     ONLY:RT_output
     use com,            ONLY:msg,of_open_close
     use vec_operate,    ONLY:sort
     use interfaces,     ONLY:DESC_write
     use nl_optics,      ONLY:NL_desc
     use stderr,         ONLY:intc
     !
     ! Working Space
     !
     character(schlen) :: X_file_name
     integer           :: i_fp,i_dsc
     logical           :: l_prt_err
     real(SP)          :: Unit_of_Measure,VALUEs(11)
     integer           :: f_indx(max_n_of_paths),n_headings
     character(schlen) :: headings(11,0:X_order),oexp
     !
     l_prt_err=.false.
     !
     Harmonic_Frequency(1,:)=Probe_Frequency(:)
     call sort(Harmonic_Frequency(1,:),indx=f_indx(:n_frequencies))
     !
     n_headings=7
     !
     headings(1,:)=" E [eV]"
     !
     ! X^1 is adimensional
     ! X^0 I don't know :-)
     ! X^n n>2 [cm/stV]^{n-1}
     !
     headings(2:7,0)=(/'X/Im(x)','X/Re(x)','X/Im(y)','X/Re(y)','X/Im(z)','X/Re(z)'/)
     headings(2:7,1)=(/'X/Im(x)','X/Re(x)','X/Im(y)','X/Re(y)','X/Im(z)','X/Re(z)'/)
     headings(2:7,2)=(/'X/Im[cm/stV](x)','X/Re[cm/stV](x)','X/Im[cm/stV](y)','X/Re[cm/stV](y)',&
&                      'X/Im[cm/stV](z)','X/Re[cm/stV](z)'/)
     do i_order=3,X_order,1
       oexp=trim(intc(i_order-1))
       headings(2:7,i_order)=(/'X/Im[cm/stV]^'//oexp//'(x)','X/Re[cm/stV]^'//oexp//'(x)',&
&                              'X/Im[cm/stV]^'//oexp//'(y)','X/Re[cm/stV]^'//oexp//'(y)',&
&                              'X/Im[cm/stV]^'//oexp//'(z)','X/Re[cm/stV]^'//oexp//'(z)'/)
     enddo
     !
     do i_order=0,X_order,1
       !
       X_file_name="YPP-X_probe_order_"//trim(intc(i_order))
       !
       call of_open_close(trim(X_file_name),'ot')
       !
       call DESC_write('o probe','#',NL_desc)
       !
       call msg('o probe','#')
       call msg('o probe','#',headings(1:n_headings,i_order),INDENT=0,USE_TABS=.TRUE.)
       call msg('o probe','#')
       !
       do i_fp=1,n_frequencies
         !
         i_f=f_indx(i_fp)
         !
         if(.not.runs_ok(i_f)) cycle
         !
         Unit_of_Measure = 1._SP
         !
         if (i_order==0) Unit_of_Measure =  SVCMm12VMm1/AU2VMm1
         if (i_order> 1) Unit_of_Measure = (SVCMm12VMm1/AU2VMm1)**(i_order-1)  
         !
         VALUEs(1)  =Probe_Frequency(i_f)*HA2EV
         VALUEs(2:7)=(/aimag(Susceptibility(i_order,i_f,1)*Unit_of_Measure),&
&                       real(Susceptibility(i_order,i_f,1)*Unit_of_Measure),&
                       aimag(Susceptibility(i_order,i_f,2)*Unit_of_Measure),&
&                       real(Susceptibility(i_order,i_f,2)*Unit_of_Measure),&
&                      aimag(Susceptibility(i_order,i_f,3)*Unit_of_Measure),&
&                       real(Susceptibility(i_order,i_f,3)*Unit_of_Measure)/)
         !
         call msg('o probe','',VALUEs(1:n_headings),USE_TABS=.TRUE.)
         !
       enddo 
       !
       call of_open_close(trim(X_file_name))
       !
     enddo
     !
   end subroutine
   !
   real(SP) function T_range_nl(i_n,i_f)
     !
     integer :: i_n,i_f
     !
     RT_conf%T_range=time_range_save
     !
     T_range_nl = EtoT(E=Harmonic_Frequency(i_n,i_f))
     !
     RT_conf%T_range(2)  = RT_conf%T_range(1)+ T_range_nl
     !
     if (RT_conf%T_range(2)> (NE_steps-1)*RT_step) then
       RT_conf%T_range(2)  = (NE_steps-1)*RT_step
       RT_conf%T_range(1)  = RT_conf%T_range(2)-T_range_nl
     endif 
     !
   end function 
   !
end subroutine
