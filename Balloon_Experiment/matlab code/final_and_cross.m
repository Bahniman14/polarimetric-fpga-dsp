%% Baloon_CrossCo -- 4-Channel Spectrometer + Cross-Correlation Viewer
%
% Run the Simulink simulation first, then run this whole script.
%
% Produces, per auto-correlation channel:
%   Figure A : Power Spectrum vs Bin Index AND vs Frequency
%   Figure B : Final (accumulated) Spectrum vs Frequency
% Plus, for each valid-flag pair and for the ch0 x ch1 cross-correlation.
%
% ------------------------------------------------------------------------
% ALIGNMENT -- two modes, chosen automatically per signal
%
% Each signal is tapped at a different pipeline depth, so its 256-sample
% frames start at an unknown offset. We anchor on the LARGEST sample in
% the stream (guaranteed part of a real peak) and test each of the 256
% possible "which bin is that sample on?" answers.
%
% UNGATED signals: a real-input power spectrum is mirror-symmetric,
% bin k == bin N-k. Score each candidate by symmetry error, break ties
% with the known tone bin.
%
% GATED signals (Mux fitted): the Mux deliberately DESTROYS that mirror,
% zeroing bins 128..255, so symmetry scoring is meaningless. Instead we
% require the upper half to be empty and pick the strongest tone bin.
%
% NOTE: only NATURAL channel order is tested, never bit-reversed. These
% Xilinx FFT blocks emit natural order; adding a bit-reversed hypothesis
% creates FALSE matches.
% ------------------------------------------------------------------------
%
% CROSS-CORRELATION ALIGNMENT -- why it is handled differently
%
% CrossIm0 is expected to be ~ZERO everywhere when ch0 and ch1 are in
% phase. A signal with no peak cannot be self-aligned -- there is nothing
% to anchor on. So we align CrossRe0 (which HAS a strong peak) and then
% apply that SAME frame offset to CrossIm0. This is valid because both
% are produced by identical parallel paths (same multiplier latency, same
% adder latency, same accumulator, same Mux gate), so they share one
% frame boundary by construction.
% ------------------------------------------------------------------------

clc;

if ~exist('out','var')
    error('No "out" variable found. Run the Simulink simulation first.');
end

Fs = 125e6;   % ADC sample rate, Hz
N  = 256;     % FFT size

% {PowerSpectrum var, FinalSpectrum var, expected bin, label}
channels = {
    'PowerSpectrum1', 'FinalSpectrum1',  32, 'Channel 0  (FFT,  bin 32)';
    'PowerSpectrum2', 'FinalSpectrum2',  32, 'Channel 1  (FFT1, bin 32)';
    'PowerSpectrum3', 'FinalSpectrum3',  32, 'Channel 2  (FFT2, bin 32)';
    'PowerSpectrum',  'FinalSpectrum',   90, 'Channel 3  (FFT3, bin 90)';
};

CROSS_BIN = 32;   % bin where ch0 and ch1 both have their tone

bins = 0:N-1;
freqAxis = bins*(Fs/N);
freqAxis(freqAxis > Fs/2) = freqAxis(freqAxis > Fs/2) - Fs;
[freqSorted, freqOrder] = sort(freqAxis);

fprintf('\n============== SPECTROMETER + CORRELATION REPORT ==============\n');

autoPeak = NaN;   % remember ch0's auto peak for the bit-width comparison

for c = 1:size(channels,1)
    powVar = channels{c,1};
    finVar = channels{c,2};
    expBin = channels{c,3};
    label  = channels{c,4};

    fprintf('\n--- %s ---\n', label);

    powSpec = local_align(out, powVar, N, Fs, expBin);
    finSpec = local_align(out, finVar, N, Fs, expBin);

    if ~isempty(powSpec) && ~isempty(finSpec)
        fprintf('  ratio Final/Power = %.6g\n', max(finSpec)/max(powSpec));
    end
    if c == 1 && ~isempty(finSpec)
        autoPeak = max(abs(finSpec));
    end

    if ~isempty(powSpec)
        figure('Name',[label ' -- Power Spectrum']);
        subplot(2,1,1);
        stem(bins, powSpec, 'filled', 'MarkerSize', 3); grid on; xlim([0 N-1]);
        xlabel('Bin Index (0-255)'); ylabel('Power');
        title([label ' -- Power Spectrum vs Bin Index']);
        subplot(2,1,2);
        plot(freqSorted/1e6, powSpec(freqOrder), 'LineWidth', 1.2); grid on;
        xlabel('Frequency (MHz)'); ylabel('Power');
        title([label ' -- Power Spectrum vs Frequency']);
    end

    if ~isempty(finSpec)
        figure('Name',[label ' -- Final Spectrum']);
        plot(freqSorted/1e6, finSpec(freqOrder), 'LineWidth', 1.2); grid on;
        xlabel('Frequency (MHz)'); ylabel('Accumulated Power');
        title([label ' -- Final Spectrum vs Frequency']);
    end
end


%% ---------- Valid flag comparison (all 4 channels) ----------
% NOTE: valid-variable numbering runs OPPOSITE to channel numbering.
validPairs = {
    'val_test3', 'val2',  'Channel 0';
    'val_test2', 'val1',  'Channel 1';
    'val_test1', 'val',   'Channel 2';
    'val_test',  'val03', 'Channel 3';
};

fprintf('\n--- Valid flag report ---\n');
for k = 1:size(validPairs,1)
    vt = local_getData(out, validPairs{k,1});
    va = local_getData(out, validPairs{k,2});
    if isempty(vt) || isempty(va), continue; end

    n = min(numel(vt), numel(va));  t = 0:n-1;

    figure('Name',[validPairs{k,3} ' -- valid flags']);
    subplot(2,1,1);
    plot(t, vt(1:n), 'LineWidth', 1.2); grid on; ylim([-0.2 1.2]);
    xlabel('Clock cycle'); ylabel('valid');
    title([validPairs{k,3} ' -- ' strrep(validPairs{k,1},'_','\_') ' ungated (expect 256)']);
    subplot(2,1,2);
    plot(t, va(1:n), 'LineWidth', 1.2); grid on; ylim([-0.2 1.2]);
    xlabel('Clock cycle'); ylabel('valid');
    title([validPairs{k,3} ' -- ' strrep(validPairs{k,2},'_','\_') ' gated (expect 128)']);

    e1 = diff([0; vt(1:n)>0; 0]); u1 = find(e1==1); d1 = find(e1==-1)-1;
    e2 = diff([0; va(1:n)>0; 0]); u2 = find(e2==1); d2 = find(e2==-1)-1;
    fprintf('%s\n', validPairs{k,3});
    if ~isempty(u1), fprintf('   %-10s widths=%s\n', validPairs{k,1}, mat2str((d1-u1+1).')); end
    if ~isempty(u2), fprintf('   %-10s widths=%s\n', validPairs{k,2}, mat2str((d2-u2+1).')); end
    if numel(u1)>=2 && numel(u2)>=2
        m = min(numel(u1),numel(u2));
        fprintf('   steady-state offset = %s (expect all 0)\n', mat2str((u2(2:m)-u1(2:m)).'));
    end
end


%% ---------- Cross-correlation: ch0 x ch1 ----------
fprintf('\n--- Cross-correlation (ch0 x ch1) ---\n');

% Align on the REAL part (it has the peak), then reuse that exact frame
% offset for the imaginary part -- see header note.
[xre, d0x, fix_] = local_align(out, 'CrossRe0', N, Fs, CROSS_BIN);
xim = [];
if ~isempty(xre)
    xim = local_applyAlign(out, 'CrossIm0', N, d0x, fix_);
end

if ~isempty(xre) && ~isempty(xim)
    reAt = xre(CROSS_BIN+1);
    imAt = xim(CROSS_BIN+1);
    mag  = hypot(reAt, imAt);
    ph   = atan2(imAt, reAt);

    fprintf('  At bin %d (%.3f MHz):\n', CROSS_BIN, CROSS_BIN*Fs/N/1e6);
    fprintf('    Real      = %+.6g\n', reAt);
    fprintf('    Imag      = %+.6g   (expect ~0 for in-phase inputs)\n', imAt);
    fprintf('    Magnitude = %.6g\n', mag);
    fprintf('    Phase     = %+.4f rad  (%+.2f deg)\n', ph, ph*180/pi);
    if abs(reAt) > 0
        fprintf('    |Imag/Real| = %.4g   (small => correctly in phase)\n', abs(imAt/reAt));
    end

    % ---- bit-width comparison: the professor's question ----
    bitsNeeded = @(v) max(1, ceil(log2(abs(v)+1))) + 1;   % +1 for sign
    fprintf('\n  Bit-width comparison:\n');
    if ~isnan(autoPeak)
        fprintf('    auto  (ch0) peak = %-12.6g -> %2d bits (unsigned)\n', ...
                autoPeak, max(1,ceil(log2(autoPeak+1))));
    end
    fprintf('    cross |peak|     = %-12.6g -> %2d bits (signed)\n', ...
            max(abs([xre(:); xim(:)])), bitsNeeded(max(abs([xre(:); xim(:)]))));

    % ---- plots ----
    figure('Name','Cross-correlation ch0 x ch1 -- Real / Imag');
    subplot(2,1,1);
    stem(bins, xre, 'filled', 'MarkerSize', 3); grid on; xlim([0 N-1]);
    xlabel('Bin Index (0-255)'); ylabel('Re\{X_0 X_1^*\}');
    title('Cross-correlation REAL part vs Bin Index');
    subplot(2,1,2);
    stem(bins, xim, 'filled', 'MarkerSize', 3); grid on; xlim([0 N-1]);
    xlabel('Bin Index (0-255)'); ylabel('Im\{X_0 X_1^*\}');
    title('Cross-correlation IMAGINARY part vs Bin Index (expect ~0)');

    figure('Name','Cross-correlation ch0 x ch1 -- vs Frequency');
    subplot(2,1,1);
    plot(freqSorted/1e6, xre(freqOrder), 'LineWidth', 1.2); grid on;
    xlabel('Frequency (MHz)'); ylabel('Real');
    title('Cross-correlation REAL vs Frequency');
    subplot(2,1,2);
    plot(freqSorted/1e6, xim(freqOrder), 'LineWidth', 1.2); grid on;
    xlabel('Frequency (MHz)'); ylabel('Imag');
    title('Cross-correlation IMAG vs Frequency');

    % magnitude and phase -- the physically meaningful pair
    magSpec = hypot(xre, xim);
    phSpec  = atan2(xim, xre);
    phSpec(magSpec < 0.01*max(magSpec)) = 0;   % suppress phase of pure noise

    figure('Name','Cross-correlation ch0 x ch1 -- Magnitude / Phase');
    subplot(2,1,1);
    stem(bins, magSpec, 'filled', 'MarkerSize', 3); grid on; xlim([0 N-1]);
    xlabel('Bin Index (0-255)'); ylabel('|X_0 X_1^*|');
    title('Cross-correlation MAGNITUDE vs Bin Index');
    subplot(2,1,2);
    stem(bins, phSpec*180/pi, 'filled', 'MarkerSize', 3); grid on; xlim([0 N-1]);
    ylim([-190 190]);
    xlabel('Bin Index (0-255)'); ylabel('Phase (deg)');
    title('Cross-correlation PHASE vs Bin Index (zeroed where magnitude is negligible)');
end

fprintf('\n===============================================================\n\n');


%% ===================== Local functions =====================

function d = local_getData(out, sigName)
    try
        sig = out.(sigName);
    catch
        d = []; return;
    end
    if isa(sig,'Simulink.SimulationData.Signal'),   d = sig.Values.Data;
    elseif isa(sig,'timeseries'),                   d = sig.Data;
    elseif isstruct(sig) && isfield(sig,'signals'), d = sig.signals.values;
    elseif isnumeric(sig),                          d = sig;
    else,                                            d = [];
    end
    if ~isempty(d), d = double(d(:)); end
end


function spec = local_applyAlign(out, sigName, N, d0, fi)
% Extract a frame using an offset already determined from a partner
% signal. Used for CrossIm0, which may have no peak of its own.
    stream = local_getData(out, sigName);
    if isempty(stream) || numel(stream) < 2*N
        fprintf('  %-16s : NOT FOUND or too short\n', sigName);
        spec = []; return;
    end
    nf = floor((numel(stream)-d0)/N);
    if nf < 1 || fi > nf
        spec = []; return;
    end
    F = reshape(stream(d0+1 : d0+nf*N), N, nf);
    spec = F(:,fi).';
end


function [spec, bestD0, bestFi] = local_align(out, sigName, N, Fs, expectedBin)
    spec = []; bestD0 = 0; bestFi = 1;
    stream = local_getData(out, sigName);
    if isempty(stream)
        fprintf('  %-16s : NOT FOUND in "out"\n', sigName);
        return;
    end
    if numel(stream) < 2*N
        fprintf('  %-16s : only %d samples, need >= %d (raise Stop Time)\n', ...
                sigName, numel(stream), 2*N);
        return;
    end

    [gmax, p] = max(abs(stream));
    if gmax <= 0
        fprintf('  %-16s : all zero\n', sigName);
        spec = stream(1:N).'; return;
    end

    kk = 2:(N/2);  mi = N - (kk-1) + 1;   % mirror pairs
    upper = (N/2+2):N;                    % bins N/2+1 .. N-1

    specs   = cell(1,N);
    offs    = nan(1,N);
    fidx    = nan(1,N);
    symErr  = nan(1,N);
    upEnrgy = nan(1,N);
    toneVal = nan(1,N);
    for b = 0:N-1
        d0 = mod(p - b - 1, N);
        nf = floor((numel(stream)-d0)/N);
        if nf < 1, continue; end
        F = reshape(stream(d0+1 : d0+nf*N), N, nf);
        [~, fi] = max(max(abs(F), [], 1));   % biggest peak = completed accumulation
        s = F(:,fi).';
        specs{b+1}   = s;
        offs(b+1)    = d0;
        fidx(b+1)    = fi;
        symErr(b+1)  = sum(abs(s(kk) - s(mi)));
        upEnrgy(b+1) = sum(abs(s(upper)));
        toneVal(b+1) = abs(s(expectedBin+1));
    end

    gated = upEnrgy <= 1e-6*gmax;    % upper half blanked => Mux gate present

    if any(gated)
        cand = find(gated);
        [~, j] = max(toneVal(cand));
        idx  = cand(j);
        mode = 'mux-gated';
    else
        tol   = min(symErr(~isnan(symErr))) + 0.01*gmax;
        cand  = find(symErr <= tol);
        cb    = cand - 1;
        score = min(abs(cb - expectedBin), abs(cb - (N - expectedBin)));
        [~, ord] = sort(score);
        cand = cand(ord);
        idx  = cand(1);
        for t = cand
            [~, pk] = max(abs(specs{t}));
            if (pk-1) == expectedBin || (pk-1) == (N - expectedBin)
                idx = t; break;
            end
        end
        mode = 'full';
    end

    spec   = specs{idx};
    bestD0 = offs(idx);
    bestFi = fidx(idx);
    [pk, pkIdx] = max(abs(spec));
    fprintf('  %-16s : %-10s peak %.6g at bin %d = %.3f MHz\n', ...
            sigName, mode, pk, pkIdx-1, (pkIdx-1)*Fs/N/1e6);
    if (pkIdx-1) ~= expectedBin && (pkIdx-1) ~= (N-expectedBin)
        fprintf('  %-16s   WARNING: expected bin %d or %d -- check tone frequency\n', ...
                '', expectedBin, N-expectedBin);
    end
end