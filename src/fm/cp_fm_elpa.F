!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2021 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Wrapper for ELPA
!> \author Ole Schuett
! **************************************************************************************************
MODULE cp_fm_elpa
   USE cp_log_handling, ONLY: cp_to_string
   USE machine, ONLY: m_cpuid, &
                      MACHINE_X86, &
                      MACHINE_CPU_GENERIC, &
                      MACHINE_X86_SSE4, &
                      MACHINE_X86_AVX, &
                      MACHINE_X86_AVX2
   USE cp_blacs_env, ONLY: cp_blacs_env_type
   USE cp_fm_basic_linalg, ONLY: cp_fm_upper_to_full
   USE cp_fm_diag_utils, ONLY: cp_fm_redistribute_start, &
                               cp_fm_redistribute_end, &
                               cp_fm_redistribute_info
   USE cp_fm_struct, ONLY: cp_fm_struct_get
   USE cp_fm_types, ONLY: cp_fm_type, &
                          cp_fm_to_fm, &
                          cp_fm_release, &
                          cp_fm_create, &
                          cp_fm_write_info
   USE cp_log_handling, ONLY: cp_get_default_logger, &
                              cp_logger_get_default_io_unit, &
                              cp_logger_type
   USE kinds, ONLY: default_string_length, &
                    dp
   USE message_passing, ONLY: mp_comm_free, &
                              mp_comm_split_direct, &
                              mp_bcast
   USE OMP_LIB, ONLY: omp_get_max_threads

#include "../base/base_uses.f90"

#if defined (__ELPA)
   USE elpa_constants, ONLY: ELPA_2STAGE_REAL_INVALID, &
                             ELPA_2STAGE_REAL_DEFAULT, &
                             ELPA_2STAGE_REAL_GENERIC, &
                             ELPA_2STAGE_REAL_GENERIC_SIMPLE, &
                             ELPA_2STAGE_REAL_BGP, &
                             ELPA_2STAGE_REAL_BGQ, &
                             ELPA_2STAGE_REAL_SSE_ASSEMBLY, &
                             ELPA_2STAGE_REAL_SSE_BLOCK2, &
                             ELPA_2STAGE_REAL_SSE_BLOCK4, &
                             ELPA_2STAGE_REAL_SSE_BLOCK6, &
                             ELPA_2STAGE_REAL_AVX_BLOCK2, &
                             ELPA_2STAGE_REAL_AVX_BLOCK4, &
                             ELPA_2STAGE_REAL_AVX_BLOCK6, &
                             ELPA_2STAGE_REAL_AVX2_BLOCK2, &
                             ELPA_2STAGE_REAL_AVX2_BLOCK4, &
                             ELPA_2STAGE_REAL_AVX2_BLOCK6, &
                             ELPA_2STAGE_REAL_AVX512_BLOCK2, &
                             ELPA_2STAGE_REAL_AVX512_BLOCK4, &
                             ELPA_2STAGE_REAL_AVX512_BLOCK6, &
                             ELPA_2STAGE_REAL_GPU
   USE elpa, ONLY: elpa_t, elpa_solver_2stage, &
                   elpa_init, elpa_uninit, &
                   elpa_allocate, elpa_deallocate, elpa_ok
#endif

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_fm_elpa'

#if defined(__ELPA)
   INTEGER, DIMENSION(19), PARAMETER :: elpa_kernel_ids = [ &
                                        ELPA_2STAGE_REAL_INVALID, & ! auto
                                        ELPA_2STAGE_REAL_GENERIC, &
                                        ELPA_2STAGE_REAL_GENERIC_SIMPLE, &
                                        ELPA_2STAGE_REAL_BGP, &
                                        ELPA_2STAGE_REAL_BGQ, &
                                        ELPA_2STAGE_REAL_SSE_ASSEMBLY, &
                                        ELPA_2STAGE_REAL_SSE_BLOCK2, &
                                        ELPA_2STAGE_REAL_SSE_BLOCK4, &
                                        ELPA_2STAGE_REAL_SSE_BLOCK6, &
                                        ELPA_2STAGE_REAL_AVX_BLOCK2, &
                                        ELPA_2STAGE_REAL_AVX_BLOCK4, &
                                        ELPA_2STAGE_REAL_AVX_BLOCK6, &
                                        ELPA_2STAGE_REAL_AVX2_BLOCK2, &
                                        ELPA_2STAGE_REAL_AVX2_BLOCK4, &
                                        ELPA_2STAGE_REAL_AVX2_BLOCK6, &
                                        ELPA_2STAGE_REAL_AVX512_BLOCK2, &
                                        ELPA_2STAGE_REAL_AVX512_BLOCK4, &
                                        ELPA_2STAGE_REAL_AVX512_BLOCK6, &
                                        ELPA_2STAGE_REAL_GPU]

   CHARACTER(len=14), DIMENSION(SIZE(elpa_kernel_ids)), PARAMETER :: &
      elpa_kernel_names = [CHARACTER(len=14) :: &
                           "AUTO", &
                           "GENERIC", &
                           "GENERIC_SIMPLE", &
                           "BGP", &
                           "BGQ", &
                           "SSE", &
                           "SSE_BLOCK2", &
                           "SSE_BLOCK4", &
                           "SSE_BLOCK6", &
                           "AVX_BLOCK2", &
                           "AVX_BLOCK4", &
                           "AVX_BLOCK6", &
                           "AVX2_BLOCK2", &
                           "AVX2_BLOCK4", &
                           "AVX2_BLOCK6", &
                           "AVX512_BLOCK2", &
                           "AVX512_BLOCK4", &
                           "AVX512_BLOCK6", &
                           "GPU"]

   CHARACTER(len=44), DIMENSION(SIZE(elpa_kernel_ids)), PARAMETER :: &
      elpa_kernel_descriptions = [CHARACTER(len=44) :: &
                                  "Automatically selected kernel", &
                                  "Generic kernel", &
                                  "Simplified generic kernel", &
                                  "Kernel optimized for IBM BGP", &
                                  "Kernel optimized for IBM BGQ", &
                                  "Kernel optimized for x86_64/SSE", &
                                  "Kernel optimized for x86_64/SSE (block=2)", &
                                  "Kernel optimized for x86_64/SSE (block=4)", &
                                  "Kernel optimized for x86_64/SSE (block=6)", &
                                  "Kernel optimized for Intel AVX (block=2)", &
                                  "Kernel optimized for Intel AVX (block=4)", &
                                  "Kernel optimized for Intel AVX (block=6)", &
                                  "Kernel optimized for Intel AVX2 (block=2)", &
                                  "Kernel optimized for Intel AVX2 (block=4)", &
                                  "Kernel optimized for Intel AVX2 (block=6)", &
                                  "Kernel optimized for Intel AVX-512 (block=2)", &
                                  "Kernel optimized for Intel AVX-512 (block=4)", &
                                  "Kernel optimized for Intel AVX-512 (block=6)", &
                                  "Kernel targeting GPUs"]

#else
   INTEGER, DIMENSION(1), PARAMETER :: elpa_kernel_ids = [-1]
   CHARACTER(len=14), DIMENSION(1), PARAMETER :: elpa_kernel_names = ["AUTO"]
   CHARACTER(len=44), DIMENSION(1), PARAMETER :: elpa_kernel_descriptions = ["Automatically selected kernel"]
#endif

   INTEGER, SAVE :: elpa_kernel = elpa_kernel_ids(1) ! auto
   LOGICAL, SAVE :: elpa_qr = .FALSE., &
                    elpa_qr_unsafe = .FALSE., &
                    elpa_should_print = .FALSE.

   PUBLIC :: cp_fm_diag_elpa, &
             set_elpa_kernel, &
             set_elpa_qr, &
             set_elpa_print, &
             elpa_kernel_ids, &
             elpa_kernel_names, &
             elpa_kernel_descriptions, &
             initialize_elpa_library, &
             finalize_elpa_library

CONTAINS

! **************************************************************************************************
!> \brief Initialize the ELPA library
! **************************************************************************************************
   SUBROUTINE initialize_elpa_library()
#if defined(__ELPA)
      IF (elpa_init(20180525) /= elpa_ok) &
         CPABORT("The linked ELPA library does not support the required API version")
#else
      CPABORT("Initialization of ELPA library requested but not enabled during build")
#endif
   END SUBROUTINE

! **************************************************************************************************
!> \brief Finalize the ELPA library
! **************************************************************************************************
   SUBROUTINE finalize_elpa_library()
#if defined(__ELPA)
      CALL elpa_uninit()
#else
      CPABORT("Finalization of ELPA library requested but not enabled during build")
#endif
   END SUBROUTINE

! **************************************************************************************************
!> \brief Sets the active ELPA kernel.
!> \param requested_kernel one of the elpa_kernel_ids
! **************************************************************************************************
   SUBROUTINE set_elpa_kernel(requested_kernel)
      INTEGER, INTENT(IN)                                :: requested_kernel

#if defined (__ELPA)
      INTEGER                                            :: cpuid
      CLASS(elpa_t), POINTER                             :: elpa_obj

      elpa_kernel = requested_kernel

      ! Resolve AUTO kernel.
      IF (elpa_kernel == ELPA_2STAGE_REAL_INVALID) THEN
         cpuid = m_cpuid()
         IF ((MACHINE_CPU_GENERIC .LT. cpuid) .AND. (cpuid .LE. MACHINE_X86)) THEN
            SELECT CASE (cpuid)
            CASE (MACHINE_X86_SSE4)
               elpa_kernel = ELPA_2STAGE_REAL_SSE_BLOCK4
            CASE (MACHINE_X86_AVX)
               elpa_kernel = ELPA_2STAGE_REAL_AVX_BLOCK4
            CASE (MACHINE_X86_AVX2)
               elpa_kernel = ELPA_2STAGE_REAL_AVX2_BLOCK4
            CASE DEFAULT
               elpa_kernel = ELPA_2STAGE_REAL_AVX512_BLOCK4
            END SELECT
         END IF

         elpa_obj => elpa_allocate()
         IF (elpa_obj%can_set("gpu", 1) == ELPA_OK) THEN
            CPWARN("ELPA GPU kernel is available, but not enabled automatically.")
            !TODO: Enable GPU kernel automatically once the segfaults have been fixed.
            !elpa_kernel = ELPA_2STAGE_REAL_GPU  ! Select GPU over CPU kernel when available.
         ENDIF
         CALL elpa_deallocate(elpa_obj)

         ! If we could not find a suitable kernel then use ELPA_2STAGE_REAL_DEFAULT.
         IF (elpa_kernel == ELPA_2STAGE_REAL_INVALID) THEN
            elpa_kernel = ELPA_2STAGE_REAL_DEFAULT
         ENDIF
      END IF
#else
      MARK_USED(requested_kernel)
#endif
   END SUBROUTINE set_elpa_kernel

! **************************************************************************************************
!> \brief Sets flags that determines if ELPA should try to use QR during diagonalization
!>        If use_qr = .TRUE., the QR step is performed only if the size of the input matrix is
!>        suitable. Check cp_fm_diag_elpa for further details.
!> \param use_qr the logical flag
!> \param use_qr_unsafe logical which determines if block size checks should be bypassed for some
!>                      ELPA versions, potentially leading to incorrect eigenvalues
! **************************************************************************************************
   SUBROUTINE set_elpa_qr(use_qr, use_qr_unsafe)
      LOGICAL, INTENT(IN)                                :: use_qr, use_qr_unsafe

      elpa_qr = use_qr
      elpa_qr_unsafe = use_qr_unsafe
   END SUBROUTINE set_elpa_qr

! **************************************************************************************************
!> \brief Sets a flag that determines if additional information about the ELPA diagonalization
!>        should be printed when the diagonalization routine is called.
!> \param flag the logical flag
! **************************************************************************************************
   SUBROUTINE set_elpa_print(flag)
      LOGICAL, INTENT(IN)                                :: flag

      elpa_should_print = flag
   END SUBROUTINE set_elpa_print

! **************************************************************************************************
!> \brief Driver routine to diagonalize a FM matrix with the ELPA library.
!> \param matrix the matrix that is diagonalized
!> \param eigenvectors eigenvectors of the input matrix
!> \param eigenvalues eigenvalues of the input matrix
! **************************************************************************************************
   SUBROUTINE cp_fm_diag_elpa(matrix, eigenvectors, eigenvalues)
      TYPE(cp_fm_type), POINTER                :: matrix, eigenvectors
      REAL(KIND=dp), DIMENSION(:)              :: eigenvalues

      CHARACTER(len=*), PARAMETER :: routineN = 'cp_fm_diag_elpa'

#if defined(__ELPA)
      INTEGER                                  :: handle
      TYPE(cp_fm_type), POINTER                :: eigenvectors_new, matrix_new
      TYPE(cp_fm_redistribute_info)            :: rdinfo

      CALL timeset(routineN, handle)

      ! Determine if the input matrix needs to be redistributed before diagonalization.
      ! Heuristics are used to determine the optimal number of CPUs for diagonalization.
      ! The redistributed matrix is stored in matrix_new, which is just a pointer
      ! to the original matrix if no redistribution is required.
      ! With ELPA, we have to make sure that all processor columns have nonzero width
      CALL cp_fm_redistribute_start(matrix, eigenvectors, matrix_new, eigenvectors_new, &
                                    caller_is_elpa=.TRUE., redist_info=rdinfo)

      ! Call ELPA on CPUs that hold the new matrix
      IF (ASSOCIATED(matrix_new)) &
         CALL cp_fm_diag_elpa_base(matrix_new, eigenvectors_new, eigenvalues, rdinfo)

      ! Redistribute results and clean up
      CALL cp_fm_redistribute_end(matrix, eigenvectors, eigenvalues, matrix_new, eigenvectors_new)

      CALL timestop(handle)
#else
      MARK_USED(matrix)
      MARK_USED(eigenvectors)
      MARK_USED(eigenvalues)

      CPABORT("CP2K compiled without the ELPA library.")
#endif
   END SUBROUTINE cp_fm_diag_elpa

#if defined(__ELPA)
! **************************************************************************************************
!> \brief Actual routine that calls ELPA to diagonalize a FM matrix.
!> \param matrix the matrix that is diagonalized
!> \param eigenvectors eigenvectors of the input matrix
!> \param eigenvalues eigenvalues of the input matrix
!> \param rdinfo ...
! **************************************************************************************************
   SUBROUTINE cp_fm_diag_elpa_base(matrix, eigenvectors, eigenvalues, rdinfo)

      TYPE(cp_fm_type), INTENT(INOUT), POINTER           :: matrix, eigenvectors
      REAL(KIND=dp), DIMENSION(:), INTENT(INOUT)         :: eigenvalues
      TYPE(cp_fm_redistribute_info), INTENT(IN)          :: rdinfo

      CHARACTER(len=*), PARAMETER :: routineN = 'cp_fm_diag_elpa_base'

      INTEGER                                            :: handle

      CLASS(elpa_t), POINTER                   :: elpa_obj
      CHARACTER(len=default_string_length)     :: kernel_name
      INTEGER                                  :: group, i, &
                                                  mypcol, myprow, n, &
                                                  n_rows, n_cols, &
                                                  nblk, neig, io_unit, &
                                                  success
      LOGICAL                                  :: use_qr, check_eigenvalues
      REAL(KIND=dp), DIMENSION(:), ALLOCATABLE :: eval, eval_noqr
      TYPE(cp_blacs_env_type), POINTER         :: context
      TYPE(cp_fm_type), POINTER                :: matrix_noqr, eigenvectors_noqr
      TYPE(cp_logger_type), POINTER            :: logger
      REAL(KIND=dp), PARAMETER                 :: th = 1.0E-14_dp
      INTEGER, DIMENSION(:), POINTER           :: ncol_locals

      CALL timeset(routineN, handle)
      NULLIFY (logger)
      NULLIFY (ncol_locals)

      check_eigenvalues = .FALSE.

      logger => cp_get_default_logger()
      io_unit = cp_logger_get_default_io_unit(logger)

      n = matrix%matrix_struct%nrow_global
      context => matrix%matrix_struct%context
      group = matrix%matrix_struct%para_env%group

      myprow = context%mepos(1)
      mypcol = context%mepos(2)

      ! elpa needs the full matrix
      CALL cp_fm_upper_to_full(matrix, eigenvectors)

      CALL cp_fm_struct_get(matrix%matrix_struct, &
                            local_leading_dimension=n_rows, &
                            ncol_local=n_cols, &
                            nrow_block=nblk, &
                            ncol_locals=ncol_locals)

      ! ELPA will fail in 'solve_tridi', with no useful error message, fail earlier
      IF (io_unit > 0 .AND. ANY(ncol_locals == 0)) THEN
         CALL rdinfo%write(io_unit)
         CALL cp_fm_write_info(matrix, io_unit)
         CPABORT("ELPA [pre-fail]: Problem contains processor column with zero width.")
      END IF

      neig = SIZE(eigenvalues, 1)
      ! Decide if matrix is suitable for ELPA to use QR
      ! The definition of what is considered a suitable matrix depends on the ELPA version
      ! The relevant ELPA files to check are
      !     - Proper matrix order:  src/elpa2/elpa2_template.F90
      !     - Proper block size:    test/Fortran/test.F90
      ! Note that the names of these files might change in different ELPA versions
      ! Matrix order must be even
      use_qr = elpa_qr .AND. (MOD(n, 2) .EQ. 0)
      ! Matrix order and block size must be greater than or equal to 64
      IF (.NOT. elpa_qr_unsafe) &
         use_qr = use_qr .AND. (n .GE. 64) .AND. (nblk .GE. 64)

      ! Check if eigenvalues computed with ELPA_QR_UNSAFE should be verified
      IF (use_qr .AND. elpa_qr_unsafe .AND. elpa_should_print) &
         check_eigenvalues = .TRUE.

      CALL mp_bcast(check_eigenvalues, matrix%matrix_struct%para_env%source, matrix%matrix_struct%para_env%group)

      IF (check_eigenvalues) THEN
         ! Allocate and initialize needed temporaries to compute eigenvalues without ELPA QR
         ALLOCATE (eval_noqr(n))
         CALL cp_fm_create(matrix=matrix_noqr, matrix_struct=matrix%matrix_struct)
         CALL cp_fm_to_fm(matrix, matrix_noqr)
         CALL cp_fm_create(matrix=eigenvectors_noqr, matrix_struct=eigenvectors%matrix_struct)
         CALL cp_fm_upper_to_full(matrix_noqr, eigenvectors_noqr)
      END IF

      IF (io_unit > 0 .AND. elpa_should_print) THEN
         WRITE (io_unit, '(/,A)') "ELPA| Matrix diagonalization information"

         ! Find name for given kernel id.
         ! In case ELPA_2STAGE_REAL_DEFAULT was used it might not be in our elpa_kernel_ids list.
         kernel_name = "id: "//TRIM(ADJUSTL(cp_to_string(elpa_kernel)))
         DO i = 1, SIZE(elpa_kernel_ids)
            IF (elpa_kernel_ids(i) == elpa_kernel) THEN
               kernel_name = elpa_kernel_names(i)
            ENDIF
         ENDDO

         WRITE (io_unit, '(A,I14)') "ELPA| Matrix order             : ", n
         WRITE (io_unit, '(A,I14)') "ELPA| Matrix block size        : ", nblk
         WRITE (io_unit, '(A,A14)') "ELPA| Kernel                   : ", ADJUSTR(TRIM(kernel_name))
         WRITE (io_unit, '(A,L14)') "ELPA| QR step requested        : ", elpa_qr

         IF (elpa_qr) THEN
            WRITE (io_unit, '(A,L14)') "ELPA| Use potentially unsafe QR: ", elpa_qr_unsafe
            WRITE (io_unit, '(A,L14)') "ELPA| Matrix is suitable for QR: ", use_qr

            IF (.NOT. use_qr) THEN
               IF (MOD(n, 2) .NE. 0) &
                  WRITE (io_unit, '(A)') "ELPA| Matrix order is NOT even"
               IF (nblk .LT. 64 .AND. .NOT. elpa_qr_unsafe) &
                  WRITE (io_unit, '(A)') "ELPA| Matrix block size is NOT 64 or greater"
            ELSE
               IF (nblk .LT. 64 .AND. elpa_qr_unsafe) &
                  WRITE (io_unit, '(A,L14)') "ELPA| Matrix block size check was bypassed"
            END IF
         END IF
      END IF

      ! the full eigenvalues vector is needed
      ALLOCATE (eval(n))

      elpa_obj => elpa_allocate()

      CALL elpa_obj%set("na", n, success)
      CPASSERT(success == elpa_ok)

      CALL elpa_obj%set("nev", neig, success)
      CPASSERT(success == elpa_ok)

      CALL elpa_obj%set("local_nrows", n_rows, success)
      CPASSERT(success == elpa_ok)

      CALL elpa_obj%set("local_ncols", n_cols, success)
      CPASSERT(success == elpa_ok)

      CALL elpa_obj%set("nblk", nblk, success)
      CPASSERT(success == elpa_ok)

      CALL elpa_obj%set("mpi_comm_parent", group, success)
      CPASSERT(success == elpa_ok)

      CALL elpa_obj%set("process_row", myprow, success)
      CPASSERT(success == elpa_ok)

      CALL elpa_obj%set("process_col", mypcol, success)
      CPASSERT(success == elpa_ok)

      success = elpa_obj%setup()
      CPASSERT(success == elpa_ok)

      CALL elpa_obj%set("solver", elpa_solver_2stage, success)
      CPASSERT(success == elpa_ok)

      ! enabling the GPU must happen before setting the kernel
      IF (elpa_kernel == ELPA_2STAGE_REAL_GPU) THEN
         CALL elpa_obj%set("gpu", 1, success)
         CPASSERT(success == elpa_ok)
      ENDIF

      CALL elpa_obj%set("real_kernel", elpa_kernel, success)
      CPASSERT(success == elpa_ok)

      IF (use_qr) THEN
         CALL elpa_obj%set("qr", 1, success)
         CPASSERT(success == elpa_ok)
      ENDIF

      ! Set number of threads only when ELPA was built with OpenMP support.
      IF (elpa_obj%can_set("omp_threads", omp_get_max_threads()) == ELPA_OK) THEN
         CALL elpa_obj%set("omp_threads", omp_get_max_threads(), success)
         CPASSERT(success == elpa_ok)
      ENDIF

      CALL elpa_obj%eigenvectors(matrix%local_data, eval, eigenvectors%local_data, success)
      IF (success /= elpa_ok) &
         CPABORT("ELPA failed to diagonalize a matrix")

      IF (check_eigenvalues) THEN
         ! run again without QR
         CALL elpa_obj%set("qr", 0, success)
         CPASSERT(success == elpa_ok)

         CALL elpa_obj%eigenvectors(matrix_noqr%local_data, eval_noqr, eigenvectors_noqr%local_data, success)
         IF (success /= elpa_ok) &
            CPABORT("ELPA failed to diagonalize a matrix even without QR decomposition")

         IF (ANY(ABS(eval(1:neig) - eval_noqr(1:neig)) .GT. th)) &
            CPABORT("Eigenvalues calculated with QR decomp. in ELPA are wrong. Disable ELPA_QR_UNSAFE.")

         DEALLOCATE (eval_noqr)
         CALL cp_fm_release(matrix_noqr)
         CALL cp_fm_release(eigenvectors_noqr)
      END IF

      CALL elpa_deallocate(elpa_obj)

      eigenvalues(1:neig) = eval(1:neig)
      DEALLOCATE (eval)

      CALL timestop(handle)

   END SUBROUTINE cp_fm_diag_elpa_base
#endif

END MODULE cp_fm_elpa

