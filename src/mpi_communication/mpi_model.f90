MODULE mpi_model

   USE mpi
   USE data_reader
   USE initialisation
   USE high_dimension
   USE low_dimension_probability
   use optimisation
   use parameters
   use timing_module

   IMPLICIT NONE

contains

  subroutine tpsd_mpi(pij_1d, point_radius_1d, low_pos_vec, results, low_results, optimisation_params, low_dim_params, rank, nranks)
      !> @brief Main function for the MPI version of the TPSD algorithm
      !> @param[in] results High dimensional results
      !> @param[out] low_results Low dimensional results
      !> @param[in] optimisation_params Optimisation parameters  
      !> @param[in] low_dim_params Low dimensional parameters
      !> @param[in] rank Rank of the current process
      !> @param[in] nranks Total number of processes
      !> @param[in] pij_1d 1D array of pairwise probabilities
      !> @param[inout] point_radius_1d 1D array of point radii
      !> @param[inout] low_pos_vec 1D array of low dimensional positions
      !> @details This function is the main function for the MPI version of the TPSD algorithm. 
      !! It is responsible for distributing the work between the processes, calculating the loss gradient and updating the low dimensional positions. 
      !! The function is split into two main phases: the exaggeration phase and the growth phase. The exaggeration phase is responsible for finding the optimal low dimensional positions for the given high dimensional data.
      !! The growth phase is responsible for expanding the point radii to ensure that the low dimensional positions are not too close to each other. The function uses the MPI library to communicate between the processes.


      ! Arguments
      type(high_dim_results), intent(in)                       :: results
      type(low_dim_results), intent(out)                       :: low_results
      type(optimisation_parameters), intent(in)                :: optimisation_params
      type(low_dim_parameters), intent(in)                     :: low_dim_params

      integer, intent(in)                                      :: rank, nranks
      real(kind=sp), intent(in)                                :: pij_1d(:)
      real(kind=sp), intent(inout)                             :: point_radius_1d(:)
      real(kind=sp), intent(inout)                             :: low_pos_vec(:)

      ! Local variables
      real(kind=sp)                                            :: exaggeration, step_size, gradient_norm, running_gradient_norm
      real(kind=sp)                                            :: point_radius_coeff, cost_criteria, z, inv_z
      real(kind=sp), dimension(:), allocatable                 :: gradient_vec, gradient_vec_noise
      integer                                                  :: i, j
      logical                                                  :: growth_step_limit = .true.

      ! MPI variables
      real(kind=sp), dimension(:), allocatable                 :: local_gradient_vec
      real(kind=sp), dimension(:, :), allocatable              :: recv_gradient_vec
      integer, dimension(nranks - 1)                           :: requests
      integer                                                  :: request
      integer                                                  :: k, start, end, ierr, task

      ! Initialisation
      task = 1
      i = 0
      j = 0
      gradient_norm = huge(1.0_sp)
      running_gradient_norm = 0.0_sp
      point_radius_coeff = 0.0_sp

      z = real(results%reduced_number_points, sp)*(real(results%reduced_number_points, sp) - 1.0_sp)
      inv_z = 1.0_sp/z

      call work_distribution(rank, nranks, results%reduced_number_points, start, end)

      if (rank == 0) then

         call start_timer()

         allocate (gradient_vec((low_dim_params%low_dimension)*(results%reduced_number_points)))
         allocate (local_gradient_vec(size(gradient_vec)))
         allocate (gradient_vec_noise(size(gradient_vec)))
         allocate (recv_gradient_vec((low_dim_params%low_dimension)*(results%reduced_number_points), (nranks - 1)))

         gradient_vec = 0.0_sp
         local_gradient_vec = 0.0_sp

         cost_criteria = (optimisation_params%threshold)*(optimisation_params%growth_coeff)

         do while ((((running_gradient_norm > log10(cost_criteria) .or. (i < 100 + optimisation_params%exag_cutoff))) .and. (i < optimisation_params%maxsteps)))
       
            i = i + 1

            exaggeration = merge(1.0_sp, optimisation_params%exaggeration_init, i > optimisation_params%exag_cutoff)

            do k = 1, nranks - 1
               call MPI_Isend(exaggeration, 1, MPI_REAL4, k, 0, MPI_COMM_WORLD, requests(k), ierr)
            end do

            call loss_gradient_position_mpi(pij_1d, low_pos_vec, local_gradient_vec, exaggeration, start, end, results, low_dim_params)

            gradient_vec = local_gradient_vec

            do k = 1, nranks - 1
               call MPI_Irecv(recv_gradient_vec(:, k), (size(gradient_vec)), MPI_REAL4, k, 1, MPI_COMM_WORLD, requests(k), ierr)
            end do

            call MPI_Waitall(nranks - 1, requests, MPI_STATUSES_IGNORE, ierr)

            gradient_vec = gradient_vec + sum(recv_gradient_vec, dim=2)

            call gradient_vec_addnoise(gradient_vec, gradient_vec_noise, 1e-2)

            call calculate_stepsize(low_pos_vec, gradient_vec_noise, step_size, init=((i == 1) .or. (i == optimisation_params%exag_cutoff)))

            low_pos_vec = low_pos_vec - step_size*gradient_vec_noise

            do k = 1, nranks - 1
               call MPI_Isend(low_pos_vec, (size(gradient_vec)), MPI_REAL4, k, 2, MPI_COMM_WORLD, requests(k), ierr)
            end do

            call MPI_Waitall(nranks - 1, requests, MPI_STATUSES_IGNORE, ierr)

            gradient_norm = dot_product(step_size*gradient_vec_noise, gradient_vec)

            running_gradient_norm = running_gradient_norm + (log10(gradient_norm) - running_gradient_norm)/min(i, 100)

            write (*, *) 'Iteration: ', i, ' Gradient norm: ', running_gradient_norm, 'step size: ', step_size

         end do

         write (*, *) 'Growth phase...'

         exaggeration = -1

         do k = 1, nranks - 1
            call MPI_Isend(exaggeration, 1, MPI_INTEGER, k, 0, MPI_COMM_WORLD, requests(k), ierr)
         end do

         call MPI_Waitall(nranks - 1, requests, MPI_STATUSES_IGNORE, ierr)

         do while (((running_gradient_norm > log10(optimisation_params%threshold)) .or. (growth_step_limit)) .and. (i + j < optimisation_params%maxsteps))

            j = j + 1

            call growth_coeff_mpi(j, optimisation_params%growth_steps, point_radius_coeff, growth_step_limit)

            do k = 1, nranks - 1
               call MPI_Isend(point_radius_coeff, 1, MPI_REAL4, k, 3, MPI_COMM_WORLD, requests(k), ierr)
            end do

            point_radius_1d = point_radius_1d*point_radius_coeff

            call loss_gradient_core_mpi(pij_1d, point_radius_1d, low_pos_vec, local_gradient_vec, start, end, results, low_dim_params, optimisation_params)

            gradient_vec = local_gradient_vec

            do k = 1, nranks - 1
               call MPI_Irecv(recv_gradient_vec(:, k), size(gradient_vec), MPI_REAL4, k, 1, MPI_COMM_WORLD, requests(k), ierr)
            end do

            call MPI_Waitall(nranks - 1, requests, MPI_STATUSES_IGNORE, ierr)

            gradient_vec = gradient_vec + sum(recv_gradient_vec, dim=2)

            call gradient_vec_addnoise(gradient_vec, gradient_vec_noise, 1e-2)

            call calculate_stepsize(low_pos_vec, gradient_vec_noise, step_size, init=(j == 1))

            low_pos_vec = low_pos_vec - step_size*gradient_vec_noise

            do k = 1, nranks - 1
               call MPI_Isend(low_pos_vec, size(low_pos_vec), MPI_REAL4, k, 2, MPI_COMM_WORLD, requests(k), ierr)
            end do

            call MPI_Waitall(nranks - 1, requests, MPI_STATUSES_IGNORE, ierr)

            gradient_norm = dot_product(step_size*gradient_vec_noise, gradient_vec)

            running_gradient_norm = running_gradient_norm + (log10(gradient_norm) - running_gradient_norm)/100

            write (*, *) 'Iteration: ', i+j, ' Gradient norm: ', running_gradient_norm, 'step size: ', step_size, 'point radius: ', sum(point_radius_1d)

         end do

         point_radius_coeff = -1

         do k = 1, nranks - 1
            call MPI_Isend(point_radius_coeff, 1, MPI_INTEGER, k, 3, MPI_COMM_WORLD, requests(k), ierr)
         end do

         call MPI_Waitall(nranks - 1, requests, MPI_STATUSES_IGNORE, ierr)

         low_results%low_dimension_position = reshape(low_pos_vec, (/low_dim_params%low_dimension, results%reduced_number_points/))

         call stop_timer()
         print *, 'Time taken: ', elapsed_time()

      else

         allocate (local_gradient_vec((low_dim_params%low_dimension)*(results%reduced_number_points)))
         local_gradient_vec = 0.0_sp

         do
            call MPI_Irecv(exaggeration, 1, MPI_REAL4, 0, 0, MPI_COMM_WORLD, request, ierr)
            call MPI_Wait(request, MPI_STATUSES_IGNORE, ierr)
            if (exaggeration == -1) exit

         call loss_gradient_position_mpi(pij_1d, low_pos_vec, local_gradient_vec, exaggeration, start, end, results, low_dim_params)

            call MPI_Isend(local_gradient_vec, size(local_gradient_vec), MPI_REAL4, 0, 1, MPI_COMM_WORLD, request, ierr)
            call MPI_Wait(request, MPI_STATUSES_IGNORE, ierr)

            call MPI_Irecv(low_pos_vec, size(low_pos_vec), MPI_REAL4, 0, 2, MPI_COMM_WORLD, request, ierr)
            call MPI_Wait(request, MPI_STATUSES_IGNORE, ierr)

         end do

         do

            call MPI_Irecv(point_radius_coeff, 1, MPI_REAL4, 0, 3, MPI_COMM_WORLD, request, ierr)
            call MPI_Wait(request, MPI_STATUSES_IGNORE, ierr)
            if (point_radius_coeff == -1) exit

            point_radius_1d = point_radius_1d*point_radius_coeff
            call loss_gradient_core_mpi(pij_1d, point_radius_1d, low_pos_vec, local_gradient_vec, start, end, results, low_dim_params, optimisation_params)

            call MPI_Isend(local_gradient_vec, size(local_gradient_vec), MPI_REAL4, 0, 1, MPI_COMM_WORLD, request, ierr)
            call MPI_Wait(request, MPI_STATUSES_IGNORE, ierr)

            call MPI_Irecv(low_pos_vec, size(low_pos_vec), MPI_REAL4, 0, 2, MPI_COMM_WORLD, request, ierr)
            call MPI_Wait(request, MPI_STATUSES_IGNORE, ierr)

         end do
      end if

   end subroutine tpsd_mpi

   subroutine loss_gradient_position_mpi(pij_1d, low_pos_vec, gradient_vec, exaggeration, start, end, results, low_dim_params)

      !> @brief Calculates the loss gradient for the low dimensional positions
      !> @param[in] results High dimensional results
      !> @param[in] low_dim_params Low dimensional parameters
      !> @param[in] exaggeration Exaggeration factor
      !> @param[in] start Start index for the loop
      !> @param[in] end End index for the loop
      !> @param[in] pij_1d 1D array of pairwise probabilities
      !> @param[inout] low_pos_vec 1D array of low dimensional positions
      !> @param[inout] gradient_vec 1D array of the gradient
      !> @details This function calculates the loss gradient for the low dimensional positions. The function is parallelised using OpenMP.

      implicit none

      ! Arguments
      type(high_dim_results), intent(in)                              :: results
      type(low_dim_parameters), intent(in)                            :: low_dim_params
      real(kind=sp), intent(in)                                       :: exaggeration
      integer, intent(in)                                             :: start, end
      real(kind=sp), intent(in)                                       :: pij_1d(:)
      real(kind=sp), intent(inout)                                    :: low_pos_vec(:), gradient_vec(:)

      ! Local variables
      real(kind=sp), allocatable                                      :: vec(:), pos(:)
      real(kind=sp)                                                   :: qij
      integer                                                         :: i, j, index_i, index_j, index_ii, index_jj, index_pij, index

      allocate (vec(low_dim_params%low_dimension))
      allocate (pos(low_dim_params%low_dimension))

      gradient_vec = 0.0_sp
      index = results%reduced_number_points
      z = real(index, sp)*(real(index, sp) - 1.0_sp)
      inv_z = 1.0_sp/z

      !$omp parallel do private(pos, qij, vec, index_i, index_j, index_ii, index_jj, index_pij) reduction(+:gradient_vec) schedule(dynamic)
      do i = start, end
         index_i = (i - 1)*low_dim_params%low_dimension + 1
         index_ii = i*low_dim_params%low_dimension
         do j = i + 1, index
            index_j = (j - 1)*low_dim_params%low_dimension + 1
            index_jj = j*low_dim_params%low_dimension
            index_pij = (j - 1)*index + i
            pos(:) = low_pos_vec(index_i:index_ii) - low_pos_vec(index_j:index_jj)
            qij = 1.0_sp/(1.0_sp + dot_product(pos, pos))*inv_z
            vec(:) = 4.0_sp*z*(exaggeration*pij_1d(index_pij) - (1 - pij_1d(index_pij))/(1 - qij)*qij)*qij*pos(:)
            gradient_vec(index_i:index_ii) = gradient_vec(index_i:index_ii) + vec(:)
            gradient_vec(index_j:index_jj) = gradient_vec(index_j:index_jj) - vec(:)
         end do
      end do
      !$omp end parallel do

      deallocate (vec)
      deallocate (pos)

   end subroutine loss_gradient_position_mpi

   subroutine loss_gradient_core_mpi(pij_1d, point_radius, low_pos_vec, gradient_vec, start, end, results, low_dim_params, optimisation_params)

      !> @brief Calculates the loss gradient during the hard sphere growth phase.
      !> @param[in] results High dimensional results
      !> @param[in] low_dim_params Low dimensional parameters
      !> @param[in] optimisation_params Optimisation parameters
      !> @param[in] start Start index for the loop
      !> @param[in] end End index for the loop
      !> @param[in] pij_1d 1D array of pairwise probabilities
      !> @param[in] point_radius 1D array of point radii
      !> @param[inout] low_pos_vec 1D array of low dimensional positions
      !> @param[inout] gradient_vec 1D array of the gradient
      !> @details This function calculates the loss gradient during the hard sphere growth phase. The function is parallelised using OpenMP.

      implicit none

      ! Arguments
      type(high_dim_results), intent(in)              :: results
      type(low_dim_parameters), intent(in)            :: low_dim_params
      type(optimisation_parameters), intent(in)       :: optimisation_params
      integer, intent(in)                             :: start, end
      real(kind=sp), intent(in)                       :: pij_1d(:)
      real(kind=sp), intent(in)                       :: point_radius(:)
      real(kind=sp), intent(inout)                    :: low_pos_vec(:), gradient_vec(:)

      ! Local variables
      real(kind=sp), allocatable                      :: vec(:), pos(:)
      real(kind=sp)                                   :: qij, rij2, dist
      integer                                         :: i, j, index_i, index_j, index_ii, index_jj, index_pij, index

      allocate (vec(low_dim_params%low_dimension))
      allocate (pos(low_dim_params%low_dimension))

      gradient_vec = 0.0_sp
      index = results%reduced_number_points
      z = real(index, sp)*(real(index, sp) - 1.0_sp)
      inv_z = 1.0_sp/z

      !$omp parallel do private(pos, rij2, qij, dist, vec, index_i, index_j, index_ii, index_jj, index_pij) reduction(+:gradient_vec) schedule(dynamic)
      do i = start, end
         index_i = (i - 1)*low_dim_params%low_dimension + 1
         index_ii = i*low_dim_params%low_dimension
         do j = i + 1, index
            index_j = (j - 1)*low_dim_params%low_dimension + 1
            index_jj = j*low_dim_params%low_dimension
            index_pij = (j - 1)*index + i
            pos(:) = low_pos_vec(index_i:index_ii) - low_pos_vec(index_j:index_jj)
            rij2 = dot_product(pos, pos)
            qij = 1.0_sp/(1.0_sp + rij2)*inv_z
            vec(:) = 4.0_sp*z*(pij_1d(index_pij) - (1 - pij_1d(index_pij))/(1 - qij)*qij)*qij*pos(:)
            gradient_vec(index_i:index_ii) = gradient_vec(index_i:index_ii) + vec(:)
            gradient_vec(index_j:index_jj) = gradient_vec(index_j:index_jj) - vec(:)

            dist = sqrt(rij2)
            if (dist < point_radius(i) + point_radius(j)) then
               vec(:) = -pos/dist
               dist = (point_radius(i) + point_radius(j) - dist)/2.0_sp
              gradient_vec(index_i:index_ii) = gradient_vec(index_i:index_ii) + vec(:)*dist*optimisation_params%core_strength/2.0_sp
              gradient_vec(index_j:index_jj) = gradient_vec(index_j:index_jj) - vec(:)*dist*optimisation_params%core_strength/2.0_sp
            end if

         end do
      end do
      !$omp end parallel do

      deallocate (vec)
      deallocate (pos)

   end subroutine loss_gradient_core_mpi

   subroutine work_distribution(rank, nranks, reduced_number_points, start, end)

      !> @brief Distributes the work between the processes
      !> @param[in] rank Rank of the current process
      !> @param[in] nranks Total number of processes
      !> @param[in] reduced_number_points Number of points after removing duplicates.
      !> @param[out] start Start index for the loop
      !> @param[out] end End index for the loop
      !> @details This function distributes the work between the processes. 
      !! The function is used to split the work between the processes in the loss gradient calculation.

      implicit none
      integer, intent(in)  :: rank, nranks, reduced_number_points
      integer, intent(out) :: start, end
      integer              :: i, total_load, load_per_rank, cumulative_load, remainder

      total_load = reduced_number_points*(reduced_number_points - 1)/2
      load_per_rank = total_load/nranks
      remainder = total_load - load_per_rank*nranks

      start = 1
      end = 0
      cumulative_load = 0

      do i = 1, reduced_number_points

         cumulative_load = cumulative_load + (reduced_number_points - i)

         if (cumulative_load >= load_per_rank*(rank) .and. start == 1 .and. rank /= 0) then
            start = i
         end if

         if (cumulative_load >= load_per_rank*(rank + 1)) then
            end = i - 1
         end if

         if (end /= 0) exit

      end do

      if (rank == nranks - 1) end = reduced_number_points

   end subroutine work_distribution

   subroutine growth_coeff_mpi(j, growth_steps, point_radius_coeff, growth_step_limit)

      !> @brief Calculates the growth coefficient for the hard sphere growth phase
      !> @param[in] j Current iteration
      !> @param[in] growth_steps Number of growth steps
      !> @param[inout] point_radius_coeff Growth coefficient
      !> @param[inout] growth_step_limit Limit for the growth steps
      !> @details This function calculates the growth coefficient for the hard sphere growth phase.
      
      implicit none

      integer, intent(in)             :: j
      integer, intent(in)             :: growth_steps
      real(kind=sp), intent(inout)    :: point_radius_coeff
      logical, intent(inout)          :: growth_step_limit

      if (j < growth_steps) then
         if (j < 2) then
            point_radius_coeff = (real(j))/real(growth_steps)
         else
            point_radius_coeff = real(j)/(real(j) - 1.0_sp)
         end if
      else
         point_radius_coeff = 1.0_sp
      end if

      if (j > (growth_steps + 100)) growth_step_limit = .false.

   end subroutine growth_coeff_mpi

end module mpi_model
