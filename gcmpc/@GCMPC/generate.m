function controller = generate(obj, n_t)
%CALCULATE_GCC This function generates a YALMIP optimizer for the GCMPC problem
%
%    Input(s):
%    (1) obj - GCMPC class instance
%    (2) n_t - GCMPC problem horizon
%
%    Output(s):
%    (1) controller - GCMPC controller instance
%
%    Author(s):
%    (1) Carlos M. Massera

    % Check depedencies
    if ~obj.is_system_set
        error('System matrices not set, define them before the generating GCC')
    end
    
    if ~obj.is_disturbance_set
        error('Disturbance matrices not set, define them before the generating GCC')
    end
    
    if ~obj.is_cost_set
        error('Cost matrices not set, define them before the generating GCC')
    end
    
    if ~obj.is_constraint_set
        warning('Cosntraint matrices not set, assuming system is unconstrained')
    end
    
    % Generate GCC and Nil-potent controllers if they are not generated
    if ~obj.is_gcc_set
        if ~obj.is_reference_set  % No reference, use GCC
            obj.calculate_gcc();
        else                      % Reference, use GCRT
            obj.calculate_gcrt();
        end
    end
    
    if ~obj.is_nilpotent_set
        obj.calculate_nilpotent();
    end
    
    % Set horizon
    obj.n_t = n_t;
    
    % Define optimization variables
    x = sdpvar(obj.n_x, obj.n_t + 1);
    v = sdpvar(obj.n_u, obj.n_t);
    u = - obj.gcc.k * x(:, 1:obj.n_t) + v;
    
    if obj.is_reference_set  % Define reference inputs, update u to have feedforward term
        r = sdpvar(obj.n_r, obj.n_t);
        u = u - obj.gcc.l * r;
    end
    
    % Define problem objective
    p = obj.gcc.p;
    r_bar = obj.gcc.r_bar;
    objective = x(:,1)' * p * x(:,1);
    for i = 1:obj.n_t
        objective = objective + v(:,i)' * r_bar * v(:,i);
    end
    obj.opt.objective = objective;
    
    % Define system dynamics constraints
    if ~obj.is_reference_set  % No reference
        constraint = (x(:,2:end) == (obj.a - obj.b_u * obj.gcc.k) * x(:,1:end-1) + obj.b_u * v);
    else                      % With reference
        constraint = (x(:,2:end) == (obj.a - obj.b_u * obj.gcc.k) * x(:,1:end-1) + ...
                                    obj.b_u * v + (obj.b_r - obj.b_u * obj.gcc.l) * r);
    end
    
    % Generate robust constraint set
    if ~obj.is_reference_set  % No reference
        cap_phi = calculate_cap_phi(obj, x, v);
    else                      % With reference
        cap_phi = calculate_cap_phi(obj, x, v, r);
    end
    
    % Add robust inequalities to optimization
    h_tilda = obj.h_x - obj.h_u * obj.gcc.k;
    
    if ~obj.is_constraint_soft  % Hard constraints
        for k = 1:obj.n_t
            constraint = [constraint;
                          h_tilda * x(:,k) + obj.h_u * v(:,k) + obj.g + cap_phi(:,k) <= 0];
        end
    else                        % Soft constraints
        slack = sdpvar(obj.n_c, obj.n_t);
        
        % Objective
        objective = objective + obj.kSlackWeight * sum(sum(slack));
        
        % Constraint slacking
        for k = 1:obj.n_t
            constraint = [constraint;
                          h_tilda * x(:,k) + obj.h_u * v(:,k) + obj.g + cap_phi(:,k) <= slack(:,k)];
        end
        constraint = [constraint; slack >= 0];
    end
    
    % Create YALMIP object
    ops = sdpsettings('solver', obj.options.solver_qp, 'verbose', 0);
    
    if ~obj.is_reference_set  % No reference as input
        controller = optimizer(constraint, objective, ops, x(:,1), u(:,1));
    else
        controller = optimizer(constraint, objective, ops, {x(:,1), r}, u(:,1));
    end

    % Save everything else
    obj.opt.objective = objective;
    obj.opt.constraint = constraint;
    obj.opt.variable.x = x;
    obj.opt.variable.u = u;
    obj.opt.variable.v = v;
    if obj.is_reference_set
        obj.opt.variable.r = r;
    end
    obj.opt.controller = controller;
end

function cap_phi = calculate_cap_phi(obj, x, v, r)
%CALCULATE_CAP_PHI Helper function to calculate capital Phi based on Lemma 4 and Theorem 3
%
%    Note: r is optional
    
    % First calculate the coeficient matrix c (Lemma 4)
    c = eye(obj.n_t);
    for k = 2:obj.n_t
        for i = 1:k-1
            for j = 0:k-i-1
                c(k,i) = c(k,i) + rho(obj, j) * c(k - j - 1, i);
            end
        end
    end
    % Stuff near zero should be zero
    c(abs(c) < obj.kZeroTest) = 0;
    
    % Calculate phi (Lemma 4)
    phi = sdpvar(1, obj.n_t);
    
    if ~obj.is_reference_set  % Without reference terms
        for k = 1:obj.n_t
            phi(k) = norm((obj.c_y - obj.d_y_u * obj.gcc.k) * x(:,k) + ...
                           obj.d_y_u * v(:,k), 2);
        end
    else                      % With reference terms
        for k = 1:obj.n_t
            phi(k) = norm((obj.c_y - obj.d_y_u * obj.gcc.k) * x(:,k) + ...
                           obj.d_y_u * v(:,k) + ...
                          (obj.d_y_r - obj.d_y_u * obj.gcc.l) * r(:,k), 2);
        end
    end
    
    % Calculate phi_bar (Theorem 3)
    phi_bar = phi * c';
    
    % Calculate the factor between capital Phi and phi_bar (Theorem 3)
    h_tilda = obj.h_x - obj.h_u * obj.gcc.k;
    a_tilda = obj.a - obj.b_u * obj.np.k;
    
    factor = zeros(obj.n_t, obj.n_t, obj.n_c);
    for i = 1:obj.n_c
        for k = 2:obj.n_t
            for j = 1:k-1
                factor(k, j, i) = ...
                    norm(h_tilda(i,:) * a_tilda ^ (k - j - 1) * obj.b_w, 2);
            end
        end
    end
    % Stuff near zero should be zero
    factor(abs(factor) < 1e-10) = 0;
    
    % Calculate capital Phi (Theorem 3)
    cap_phi = sdpvar(obj.n_c, obj.n_t);
    for i = 1:obj.n_c
        cap_phi(i, :) = phi_bar * factor(:, :, i)';
    end
end

function x = rho(obj, i)
%RHO Helper function to calculate terms of c matrix (Lemma 4)
    
    x = norm((obj.c_y - obj.d_y_u * obj.gcc.k) * (obj.np.a_cl ^ i) * obj.b_w, 2);
end