
% timeSeries - holds all trial information (NT = number of trials)
%   timeSeries.y          = spikes at each time (one long vector) 
%   timeSeries.trialIndex = NT x 2 matrix, each row holds the start and end
%                           indices for each trial (with respect to timeSeries.y)
%   timeSeries.trCoh        = coherence for each trial
%
function [ RampFit, RampSamples] = fitRampingModel(timeSeries,params)


totalSamples = params.MCMC.nSamples+params.MCMC.burnIn;
TT = size(timeSeries.y,1);
NT = size(timeSeries.trialIndex,1);
NC = max(timeSeries.trCoh);


%% max firing rate (bound) initialization ------------------------------
%firingRateFunc   = @(X) log(1+exp(X))*params.delta_t;
firingRateFuncInv = @(X) log(exp(X/params.delta_t)-1);
timeIndices = timeSeries.trialIndex(: ,1);
timeIndices = [timeIndices;timeIndices+1;timeIndices+2]; 
startFR = firingRateFuncInv(  max(mean( timeSeries.y(timeIndices )), 1e-20));

timeIndices = timeSeries.trialIndex(timeSeries.choice == 1 ,2);
timeIndices = [timeIndices;timeIndices-1;timeIndices-2]; 
endFR1 = firingRateFuncInv(  max(mean( timeSeries.y(timeIndices )), 1e-20));

timeIndices = timeSeries.trialIndex(timeSeries.choice == 2 ,2);
timeIndices = [timeIndices;timeIndices-1;timeIndices-2]; 
endFR2 = firingRateFuncInv(  max(mean( timeSeries.y(timeIndices )), 1e-20));

initialGamma = max(startFR,max(endFR1,endFR2)); %initial gamma is the max of: beginning firing rate, end trial firing rate for choice 1, or end trial firing rate for choice 2 trials 
initialGamma = min(max(10,initialGamma),80); %keep initial gamma within some bounds


%% Sets up space for sampling --------------------------------------
RampSamples.betas        = zeros(totalSamples,NC);
RampSamples.w2s          = zeros(totalSamples,1);
RampSamples.auxThreshold = zeros(NT,totalSamples); %auxiliary variable to say when (if) bound was hit on each trial for each sample of lambda


RampSamples.l_0      = zeros(totalSamples,1);
RampSamples.gammas   = zeros(totalSamples,1);

acceptanceCount.g  = 0;
acceptanceCount.sample = zeros(totalSamples,1);

%special functions that save temp files to keep latent variables from taking over too much RAM
resetLatentsDB(length(timeSeries.y), totalSamples);
saveLatentsDB(RampingFit.lambdas,1);

%% initial values
RampSamples.betas(1,:) = 0;
RampSamples.w2s(1,:)   = 0.005;
RampSamples.l_0(1)     = 0.5;
RampSamples.gammas(1)  = initialGamma;

RampSamples.rb.sig = zeros([timeSeries.B+1,totalSamples]); %keeps this around for potential Rao-Blackwell estimates over betas
RampSamples.rb.mu  = zeros([timeSeries.B+1,totalSamples]);


%% prior parameters setup
%makes prior param structures fit the number of params
%  -the same prior might be used for several param values

beta_mu = params.rampPrior.beta_mu;
if(timeSeries.B > 1 && length(beta_mu) == 1)
    beta_mu = repmat(beta_mu,NC,1);
end
beta_sigma = params.rampPrior.beta_sigma;
if(timeSeries.B > 1 && length(beta_sigma) == 1)
    beta_sigma = repmat(beta_sigma,NC,1);
end


p_init  = zeros(timeSeries.B+1,timeSeries.B+1);
p = zeros(size(p_init));
c_init  = zeros(timeSeries.B+1,1);
c = zeros(size(c_init));

for b = 1:timeSeries.B 
    p_init(b,b) = 1/beta_sigma(b).^2;
    c_init(b)     = beta_mu(b) / beta_sigma(b).^2;
end
c_init(end) = params.l0_mu_bound/params.l0_sigma_bound^2;
p_init(end,end) = 1/params.l0_sigma_bound^2;


%% Setting up the GPU variables
trIndex = zeros(NT+1,1);

betaVector = zeros(TT+1,1);
maxTrLength = 0;
for tr = 1:NT
    T1 = timeSeries.trialIndex(tr,1);
    T2 = timeSeries.trialIndex(tr,2);
    T = T2 - T1 + 1;
    maxTrLength = max(T,maxTrLength);
    
    trIndex(tr+1) = trIndex(tr) + T;
    
    betaVector(T1:T2) = timeSeries.trCoh(tr)-1;
end

lambdaBlockSize = 50; %how often to pull samples back from GPU

lambdaCounter  = 0;
lambdaBlockNum = 0;

gpu_lambda       = kcArrayToGPU( loadLatentsDB(1:min(lambdaBlockSize,totalSamples))); %latent variables are loaded/unloaded in blocks to the GPU
gpu_auxThreshold = kcArrayToGPUint( int32(RampSamples.auxThreshold(:,1:min(lambdaBlockSize,totalSamples))));
gpu_y            = kcArrayToGPU( timeSeries.y);
gpu_trIndex      = kcArrayToGPUint(int32(trIndex));      
gpu_trBetaIndex  = kcArrayToGPUint(int32(betaVector)); 

%% run the sampler

display('Starting Ramping MCMC sampler...');

for ss = 2:totalSamples
    if(mod(ss,250) == 0 || ss == totalSamples)
        display(['  Ramping MCMC sample ' num2str(ss) ' / ' num2str(totalSamples)]);
    end
    
    
    %% sample latent states
    c(1:end) = c_init;
    p(1:end,1:end) = p_init;
    gpu_lambdaN       = kcArrayGetColumn(gpu_lambda,mod(lambdaCounter+1,lambdaBlockSize));
    gpu_auxThresholdN = kcArrayGetColumnInt(gpu_auxThreshold,mod(lambdaCounter+1,lambdaBlockSize));

    kcRampPathSampler(gpu_lambdaN,gpu_auxThresholdN,gpu_y,gpu_trIndex,gpu_trBetaIndex,RampSamples.betas(ss-1,:),RampSamples.w2s(ss-1),RampSamples.l_0(ss-1),RampSamples.gammas(ss-1),params.delta_t, params.rampSampler.numParticles, params.rampSampler.minNumParticles,params.rampSampler.sigMult,maxTrLength, c, p);
    
    lambdaCounter = mod(lambdaCounter+1,lambdaBlockSize);
    if(lambdaCounter == lambdaBlockSize-1) 
        saveLatentsDB(kcArrayToHost(gpu_lambda),(1:lambdaBlockSize) + lambdaBlockNum*lambdaBlockSize);
        RampSamples.auxThreshold(:,(1:lambdaBlockSize) + lambdaBlockNum*lambdaBlockSize) = kcArrayToHostint(gpu_auxThreshold);
        lambdaBlockNum = lambdaBlockNum + 1;
    end   
   
    %% Sample betas, l_0
    mu = p\c;
    sig = inv(p);
    RampSamples.rb.sig(:,ss) = diag(sig);
    RampSamples.rb.mu(:,ss) = mu;
    
    maxSample = 100; %samples, and resamples l_0 until a value below 1 is found (truncating the multivariate normal)
    for sampleAttempt = 1:maxSample
        driftSample = mvnrnd(mu,sig);
        if(ss < 500 && ss < params.burnIn(2))

            if(driftSample(end) < 0.95)
                break;
            elseif(maxSample == sampleAttempt)
                display('l_0 going too high!');
                driftSample(end) = 0.95;
            end
        else
            if(driftSample(end) < 1)
                break;
            elseif(maxSample == sampleAttempt)
                display('l_0 going too high!');
                driftSample(end) = 1 - 1e-4;
            end
        end
    end
        
    RampSamples.betas(ss,:) = driftSample(1:end-1);

    RampSamples.l_0(ss) = driftSample(end);
    
    if(sum(isnan( driftSample))>0)
        error('Unknown problem with sampling drift rates.');
    end
    
    %% Sample w^2
    [w1_c, w2_c] = kcGetVarianceStatsAux(gpu_lambdaN,gpu_auxThresholdN,gpu_trIndex,gpu_trBetaIndex,RampSamples.betas(ss,:),RampSamples.l_0(ss));
    w2s_1 = sum(w1_c);
    w2s_2 = sum(w2_c);
    
    RampSamples.w2s(ss) = 1./gamrnd(params.w2_p1_bound + w2s_1,1./(params.w2_p2_bound + w2s_2)); %gamrnd does not use (alpha,beta) param, uses the one with theta on the wikipedia page for gamma dist
    if(isnan( RampSamples.w2s(ss) ) || RampSamples.w2s(ss)  > 0.5)
        display('Fuck the variance');
    end
    
    
    %% Step size setup for MALA on parameters
    if(particleParams.learnStepSize.on)
        if(ss <= 2)
            g_delta = min(particleParams.learnStepSize.start);
            timeSinceLangevinAdjusted = 0;
            if(~params.silent)
                fprintf('Starting Langevin step size at %f\n',g_delta);
            end
        elseif(ss >= particleParams.learnStepSize.burnIn)
            %g_delta = particleParams.g_delta;
            if(ss == particleParams.learnStepSize.burnIn && ~params.silent)
                fprintf('Fixing Langevin step size to %f\n',g_delta);
            end
        elseif(mod(ss-1, particleParams.learnStepSize.adjustTime) == 0)
            acceptPercent = mean(acceptanceCount.sample(ss-particleParams.learnStepSize.adjustTime:ss-1));
            timeSinceLangevinAdjusted = timeSinceLangevinAdjusted + 1;
            if(g_delta > particleParams.learnStepSize.minDelta && (acceptPercent < particleParams.learnStepSize.minAcceptPercent))
                g_delta = max(g_delta/particleParams.learnStepSize.adjustStepDown,particleParams.learnStepSize.minDelta);
                timeSinceLangevinAdjusted = 0;    
                
                if(~params.silent)
                    fprintf('Adjusting Langevin step size down to %f\n',g_delta);
                end
            elseif(g_delta < particleParams.g_delta && (acceptPercent > particleParams.learnStepSize.maxAcceptPercent || (timeSinceLangevinAdjusted == particleParams.learnStepSize.adjustTimeAutoUp && particleParams.learnStepSize.adjustTime+ss<particleParams.learnStepSize.burnIn && g_delta < particleParams.g_delta && acceptPercent > 0.4) ))
                g_delta = min(g_delta*particleParams.learnStepSize.adjustStepUp,particleParams.g_delta);
                timeSinceLangevinAdjusted = 0;
                if(~params.silent)
                    fprintf('Adjusting Langevin step size up to %f\n',g_delta);
                end
            end
        end
    else
        if(sum(ss <= particleParams.g_delta_init_time) > 0) 
            g_delta = min(particleParams.g_delta_init(ss <= particleParams.g_delta_init_time));
        else
            g_delta = particleParams.g_delta;
        end
    end
    if(ss >= particleParams.learnStepSize.burnIn)
        g_delta = particleParams.g_delta ;
    end
    
    %% MALA sample gamma
    gamma_a = params.gamma_1;
    gamma_b = params.gamma_2;
    
    G_prior = -(gamma_a-1)/RampSamples.gammas(ss-1)^2;
    [log_p_lambda, der_log_p_y, G_log_p_y] = kcLangevinStepAux(gpu_lambdaN,gpu_auxThresholdN,gpu_y,gpu_trIndex,RampSamples.gammas(ss-1),params.delta_t,G_prior);
    p_mu = RampSamples.gammas(ss-1) + 1/2*g_delta^2*(G_log_p_y\der_log_p_y);

    p_sig = (g_delta)^2/G_log_p_y;
    gamma_star = p_mu + sqrt(p_sig)*randn;
    log_q_star = -1/2*log(2*pi*p_sig) - 1/(2*p_sig)*(gamma_star - p_mu)^2;
    
    G_prior_star = -(params.gamma_1-1)/gamma_star^2;
    [log_p_lambda_star, der_log_p_y_star, G_log_p_y_star] = kcLangevinStepAux(gpu_lambdaN,gpu_auxThresholdN,gpu_y,gpu_trIndex,gamma_star,params.delta_t,G_prior_star);
    p_mu_star  = gamma_star + 1/2*g_delta^2*(G_log_p_y_star\der_log_p_y_star);
    p_sig_star = (g_delta)^2/G_log_p_y_star;
    log_q = -1/2*log(2*pi*p_sig_star) - 1/(2*p_sig_star)*(RampSamples.gammas(ss-1) - p_mu_star)^2;
    
    if(gamma_a > 0 && gamma_b > 0)
        log_p      = log_p_lambda      + gamma_a*log(gamma_b) - gammaln(gamma_a) + (gamma_a-1) * log(RampSamples.gammas(ss-1))    - gamma_b*RampSamples.gammas(ss-1);
        log_p_star = log_p_lambda_star + gamma_a*log(gamma_b) - gammaln(gamma_a) + (gamma_a-1) * log(gamma_star) - gamma_b*gamma_star;
    else
        log_p      = log_p_lambda      - log(RampSamples.gammas(ss-1));
        log_p_star = log_p_lambda_star - log(gamma_star);
    end
    
    log_a = log_p_star + log_q - log_p - log_q_star;
    lrand = log(rand);
    if(gamma_star > 0 && lrand < log_a)
        RampSamples.gammas(ss) = gamma_star;
        acceptanceCount.g = acceptanceCount.g+1;
        acceptanceCount.sample(ss) = 1;
    else
        RampSamples.gammas(ss) = RampSamples.gammas(ss-1);
        acceptanceCount.sample(ss) = 0;
    end
    
%     if(s < 100)
%         DiffToBoundSamples.gammas(s) = 50;
%     end
    
    %% plot outputs
    if(mod(ss,50) == 0)
        
        if(~params.silent)
            display([ 'ac.g = '  num2str(acceptanceCount.g / (ss-1)) ' (MALA-epsilon = ' num2str(g_delta) '),  w2 = ' num2str(RampSamples.w2s(ss,:)), '  l_0 = ' num2str(RampSamples.l_0(ss,:)), '  g = ' num2str(RampSamples.gammas(ss)), '  bs = ' num2str(RampSamples.betas(ss,:))]) 
        end
        
        
        if(exist('paramPlotFigure','var') && ishandle(paramPlotFigure))
            set(0,'CurrentFigure',paramPlotFigure);
        else
            paramPlotFigure = figure(200+cellNum);
        end
        
        clf

        startMean = max(1,ss-250);
        if(ss > params.burnIn(2) + 100)
            startMean = params.burnIn(2)+1;
        end
        
        subplot(4,1,1)
        hold on
        plot(1:ss,RampSamples.betas(1:ss,:));
        title('betas');
        if(isfield(timeSeries,'actualPs'))
            plot([1 totalSamples],repmat(timeSeries.actualPs.betasB,2,1),'--');
        end
        
        meanB = mean(RampSamples.betas(startMean:ss,:));
        plot([1 totalSamples],[meanB;meanB],':');
        xlim([1 totalSamples]);
        hold off
        
        subplot(4,1,2)
        hold on
        plot(1:ss,RampSamples.w2s(1:ss,:));
        title('w2s');
        if(isfield(timeSeries,'actualPs'))
            plot([1 totalSamples],repmat(timeSeries.actualPs.w2sB,2,1),'--');
        end
        meanW2 = mean(RampSamples.w2s(startMean:ss));
        plot([1 totalSamples],[meanW2 meanW2],':k');
        xlim([1 totalSamples]);
        hold off
        
        subplot(4,1,3)
        hold on
        plot(1:ss,RampSamples.l_0(1:ss));
        title('l_0');
        if(isfield(timeSeries,'actualPs'))
            plot([1 totalSamples],repmat(timeSeries.actualPs.l_0B,2,1),'--');
        end
        meanL0 = mean(RampSamples.l_0(startMean:ss));
        plot([1 totalSamples],[meanL0 meanL0],':k');
        xlim([1 totalSamples]);
        hold off
        
        
        subplot(4,1,4)
        hold on
        plot(1:ss,RampSamples.gammas(1:ss));
        title(['gamma, acceptance percentage = ' num2str(acceptanceCount.g / (ss-1)*100) '%']);
        if(isfield(timeSeries,'actualPs'))
            plot([1 totalSamples],repmat(timeSeries.actualPs.gamma,2,1),'--');
        end
        meanGamma = mean(RampSamples.gammas(startMean:ss));
        plot([1 totalSamples],[meanGamma meanGamma],':k');
        xlim([1 totalSamples]);
        hold off
        
        if(exist('latentStateFigure','var') && ishandle(latentStateFigure))
            set(0,'CurrentFigure',latentStateFigure);
        else
            latentStateFigure = figure(18);
        end
        clf
        hold on
        
        
        range = [];
        allTrs = [];
        for ii = 1:timeSeries.B 
            nTrialsAtCoh = sum(timeSeries.trB == ii);
            trs = find(timeSeries.trB == ii,1);
            range = [range timeSeries.trialIndex(trs,1):timeSeries.trialIndex(trs+min(3,nTrialsAtCoh)-1,2) ]; %#ok<AGROW>
            allTrs = [allTrs trs:(trs+min(3,nTrialsAtCoh)-1)]; %#ok<AGROW>
        end
        
        
        trialsToPlot = max(1,ss-100):ss;
        gMult = repmat(RampSamples.gammas(trialsToPlot)',length(range),1);
        if(params.logLinTransfer)
            tFunc = @(x) log(1+exp(x))*params.delta_t;
        else
            tFunc = @(x) exp(x)*params.delta_t;
        end
        
        latentBlock = loadLatentsDB(trialsToPlot);
        for ii = 1:length(allTrs)
            for jj = 1:length(trialsToPlot)
                T1 = timeSeries.trialIndex(allTrs(ii),1);
                T2 = timeSeries.trialIndex(allTrs(ii),2);
                
                tc = find(latentBlock(T1:T2,jj) >= 1,1);
                if(~isempty(tc))
                    latentBlock(T1+tc-1:T2,jj) = 1;
                end
            end
        end
        plot(1:length(range),tFunc(latentBlock(range,:).*gMult),'b');
        plot(1:length(range),timeSeries.y(range),'r');
        hold off
        
        
        drawnow;
        
    end
    
    if(mod(ss,params.GPUresetTime) == 0)
        if(~params.silent)
            display('Reloading the GPU data and pausing...');
        end
        kcFreeGPUArray(gpu_y);
        kcFreeGPUArray(gpu_lambda);
        kcFreeGPUArray(gpu_auxThreshold);
        kcFreeGPUArray(gpu_trIndex);
        kcFreeGPUArray(gpu_trBetaIndex);
        kcResetDevice;
        pause(1);

        gpu_lambda       = kcArrayToGPU( loadLatentsDB((1:lambdaBlockSize) + (lambdaBlockNum-1)*lambdaBlockSize) );
        gpu_auxThreshold = kcArrayToGPUint(int32( RampSamples.auxThreshold(:,(1:lambdaBlockSize) + (lambdaBlockNum-1)*lambdaBlockSize)) );
        gpu_y            = kcArrayToGPU( timeSeries.y);
        gpu_trIndex      = kcArrayToGPUint(int32(trIndex)); 
        gpu_trBetaIndex  = kcArrayToGPUint(int32(betaVector)); 

        pause(1);
        if(~params.silent)
            display('Done.');    
        end
    end
    if(mod(ss,params.GPUpauseTime) == 0)
        pause(params.GPUpauseLength);
    end
end


%% finish up---------------------------------------
thinRate = params.thinRate(1);

%get sampling stats for path
RampSamples.burnIn = max(min(params.burnIn(2),totalSamples - 10),1);
try
    RampSamples.mean   = meanLatentsDB((params.burnIn(2)+1):thinRate:totalSamples);
catch exc %#ok<NASGU>
    RampSamples.mean   = [];
end
RampSamples.median = RampSamples.mean;%median(DiffToBoundSamples.lambdas(:,params.burnIn(2):end),2);

RampSamples.meanBeta  = mean(RampSamples.betas(params.burnIn(2)+1:thinRate:end,:))';
RampSamples.meanW2    = mean(RampSamples.w2s(params.burnIn(2)+1:thinRate:end))';
RampSamples.meanGamma = mean(RampSamples.gammas(params.burnIn(2)+1:thinRate:end))';
RampSamples.meanL0    = mean(RampSamples.l_0(params.burnIn(2)+1:thinRate:end))';

try 
    kcFreeGPUArray(gpu_y);
    kcFreeGPUArray(gpu_lambda);
    kcFreeGPUArray(gpu_auxThreshold);
    kcFreeGPUArray(gpu_trIndex);
    kcFreeGPUArray(gpu_trBetaIndex);
catch e
    display(['Error clearing cuda memory: ' e]);
end




display('Done.');