%% final_and_cross.m -- Baloon_CrossCo: 4 auto channels + 6 cross baselines
%
% Run the Simulink simulation first, then run this whole script.
%
% FIGURES
%   1-4  Auto channel k: power spectrum vs bin, vs frequency, final (16-bit) spectrum
%   5    Valid flags, all 4 channels (ungated vs gated)
%   6    Cross baselines: Real and Imag vs bin (6 panels)
%   7    Cross baselines: Magnitude and Phase vs frequency (6 x 2 panels)
%   8    Cross summary: magnitude and phase at the tone bin, measured vs expected
% Plus a printed report with PASS / CHECK per channel and per baseline.
%
% ------------------------------------------------------------------------
% EDIT THIS TABLE WHEN YOU CHANGE THE SINE WAVE BLOCKS.
% Expected values are computed from it, so the checks follow your inputs:
%   bin k      = Frequency * 256 / (2*pi)       (0.785398 -> 32, 2.208932 -> 90)
%   auto peak  = A^2 * 4      (16-bit output, acc_len 16)   A=60 -> 14,400
%   cross |X|  = A_a * A_b    (same bin only, else 0)       60x60 -> 3,600
%   cross phase = phase_a - phase_b
% ------------------------------------------------------------------------
SRC = [ % bin  phase(rad)  amplitude      Sine block
          32,  0,          60;          % ch0  Sine Wave1
          32,  0,          60;          % ch1  Sine Wave2
          32,  pi/2,       60;          % ch2  Sine Wave3
          90,  0,          60 ];        % ch3  Sine Wave4
ACC_LEN = 16;
% ------------------------------------------------------------------------
%
% ALIGNMENT
% Each logged signal is tapped at a different pipeline depth, so its
% 256-sample frames start at an unknown offset.
%  * Auto channels align themselves (largest sample, then mirror symmetry
%    for ungated signals or "upper half empty" for gated ones). Natural
%    channel order only -- adding a bit-reversed hypothesis creates false
%    matches.
%  * Cross baselines can be zero (uncorrelated pairs) and a zero signal
%    cannot align itself. So ONE offset is found on the strongest baseline
%    and reused for all six: they are identical hardware paths and share a
%    frame boundary. The other baselines' peak bins and phases are then
%    genuine checks, not forced.

clc;
if ~exist('out','var')
    error('No "out" variable found. Run the Simulink simulation first.');
end

Fs = 125e6;  N = 256;  bins = 0:N-1;  df = Fs/N;
pos  = 0:N/2-1;                       % bins that survive the Mux gate
fPos = pos*df/1e6;                    % MHz
freqAxis = bins*df;  freqAxis(freqAxis > Fs/2) = freqAxis(freqAxis > Fs/2) - Fs;
[freqSorted, freqOrder] = sort(freqAxis);

autoCh = {   % PowerSpectrum var, FinalSpectrum var   (suffixes are rotated!)
    'PowerSpectrum1', 'FinalSpectrum1';    % ch0
    'PowerSpectrum2', 'FinalSpectrum2';    % ch1
    'PowerSpectrum3', 'FinalSpectrum3';    % ch2
    'PowerSpectrum',  'FinalSpectrum' };   % ch3

validPairs = {   % ungated, gated   (numbering runs OPPOSITE to channels!)
    'val_test3', 'val2';    % ch0
    'val_test2', 'val1';    % ch1
    'val_test1', 'val';     % ch2
    'val_test',  'val03' }; % ch3

XB = {  % A  B  Re var      Im var
        0, 1, 'CrossRe0', 'CrossIm0';
        0, 2, 'CrossRe1', 'CrossIm1';
        0, 3, 'CrossRe2', 'CrossIm2';
        1, 2, 'CrossRe3', 'CrossIm3';
        1, 3, 'CrossRe4', 'CrossIm4';
        2, 3, 'CrossRe5', 'CrossIm5' };

fprintf('================ SPECTROMETER + CORRELATION REPORT ================\n');

%% ===================== 1. Auto-correlation =====================
fprintf('\n--- Auto-correlation (16-bit final spectra) ---\n');
autoRes = nan(4,3);   % [peak bin, peak value, expected]
for c = 1:4
    k = SRC(c,1);  A = SRC(c,3);
    expPk = A^2 * 4 * ACC_LEN/16;
    label = sprintf('Channel %d (bin %d, %.3f MHz)', c-1, k, k*df/1e6);
    fprintf('%s\n', label);

    powSpec = local_align(out, autoCh{c,1}, N, Fs, k);
    finSpec = local_align(out, autoCh{c,2}, N, Fs, k);

    figure('Name', sprintf('Auto ch%d', c-1), 'Color', 'w');
    if ~isempty(powSpec)
        subplot(3,1,1);
        stem(bins, powSpec, 'filled', 'MarkerSize', 3); grid on; xlim([0 N-1]);
        xlabel('Bin'); ylabel('Power'); title([label ' -- power spectrum (one frame) vs bin']);
        subplot(3,1,2);
        plot(freqSorted/1e6, powSpec(freqOrder), 'LineWidth', 1.2); grid on;
        xlabel('Frequency (MHz)'); ylabel('Power'); title('Power spectrum vs frequency (both halves)');
    end
    if ~isempty(finSpec)
        subplot(3,1,3);
        stem(fPos, finSpec(pos+1), 'filled', 'MarkerSize', 3); grid on; xlim([0 fPos(end)]);
        xlabel('Frequency (MHz)'); ylabel('16-bit value');
        title(sprintf('Final spectrum (16-bit, %d frames, positive half) -- expect %.0f at %.3f MHz', ...
              ACC_LEN, expPk, k*df/1e6));

        [pk, pb] = max(finSpec(pos+1));  pb = pb - 1;
        upperEmpty = all(finSpec(N/2+1:end) == 0);
        ok = pb == k && abs(pk/expPk - 1) < 0.03 && upperEmpty;
        autoRes(c,:) = [pb pk expPk];
        if ~isempty(powSpec)
            fprintf('   Final/Power ratio = %.4g (expect %d)\n', max(finSpec)/max(powSpec)*65536, ACC_LEN);
        end
        fprintf('   16-bit peak %d at bin %d, expected %.0f at bin %d, upper half %s  -> %s\n', ...
            pk, pb, expPk, k, tern(upperEmpty,'empty','NOT EMPTY'), tern(ok,'PASS','CHECK'));
    end
end

%% ===================== 2. Valid flags =====================
fprintf('\n--- Valid flags ---\n');
figure('Name', 'Valid flags', 'Color', 'w');
for c = 1:4
    vt = local_getData(out, validPairs{c,1});
    va = local_getData(out, validPairs{c,2});
    if isempty(vt) || isempty(va)
        fprintf('Channel %d: %s / %s not found\n', c-1, validPairs{c,1}, validPairs{c,2});
        continue;
    end
    n = min(numel(vt), numel(va));  t = 0:n-1;
    subplot(4,2,2*c-1);
    plot(t, vt(1:n), 'LineWidth', 1.1); grid on; ylim([-0.2 1.2]);
    title(sprintf('ch%d  %s -- ungated (expect 256 wide)', c-1, strrep(validPairs{c,1},'_','\_')));
    subplot(4,2,2*c);
    plot(t, va(1:n), 'LineWidth', 1.1); grid on; ylim([-0.2 1.2]);
    title(sprintf('ch%d  %s -- gated (expect 128 wide)', c-1, strrep(validPairs{c,2},'_','\_')));
    if c == 4, subplot(4,2,7); xlabel('Clock'); subplot(4,2,8); xlabel('Clock'); end

    [u1,w1] = pulses(vt(1:n));  [u2,w2] = pulses(va(1:n));
    off = [];
    m = min(numel(u1), numel(u2));
    if m >= 2, off = u2(2:m) - u1(2:m); end
    ok = ~isempty(w2) && all(w2(2:end) == N/2) && all(off == 0);
    fprintf('Channel %d: ungated widths %s | gated widths %s | offset %s  -> %s\n', ...
        c-1, mat2str(w1(:).'), mat2str(w2(:).'), mat2str(off(:).'), tern(ok,'PASS','CHECK'));
end

%% ===================== 3. Cross-correlation =====================
fprintf('\n--- Cross-correlation, 6 baselines ---\n');

% raw streams
nb = size(XB,1);  R = cell(nb,1);  I = cell(nb,1);
for b = 1:nb
    R{b} = local_getData(out, XB{b,3});
    I{b} = local_getData(out, XB{b,4});
    if any([R{b}; I{b}] >= 32768)
        warning('%s/%s contain values >= 32768: a Reinterpret (Signed) block is missing.', ...
                XB{b,3}, XB{b,4});
    end
end

% expected value per baseline, from the SRC table
expX = zeros(nb,1);  expK = nan(nb,1);
for b = 1:nb
    a = XB{b,1}+1;  c = XB{b,2}+1;
    if SRC(a,1) == SRC(c,1)
        expX(b) = SRC(a,3)*SRC(c,3)*ACC_LEN/16 * exp(1i*(SRC(a,2) - SRC(c,2)));
        expK(b) = SRC(a,1);
    end
end

% one frame offset, from the strongest baseline
[~, ref] = max(abs(expX));
if isempty(R{ref}), error('%s not found -- check the To Workspace names.', XB{ref,3}); end
K = expK(ref);
mag = hypot(R{ref}, I{ref});
[~, p] = max(mag);
d0 = mod(p - K - 1, N);
nf = floor((numel(mag) - d0)/N);
Fm = reshape(mag(d0+1 : d0+nf*N), N, nf);
[~, fi] = max(Fm(K+1,:));                       % a completed integration
fprintf('Frame offset taken from %dx%d: %d samples, frame %d of %d\n\n', ...
        XB{ref,1}, XB{ref,2}, d0, fi, nf);

fprintf(' Base |  Re@tone |  Im@tone |   |X| | expect |X| | phase | expect | peak bin | upper | verdict\n');
fprintf('------+----------+----------+-------+------------+-------+--------+----------+-------+--------\n');

Xre = zeros(nb,N);  Xim = zeros(nb,N);  found = false(nb,1);
summary = nan(nb,4);   % |X| meas, |X| exp, phase meas, phase exp
for b = 1:nb
    r = frame(R{b}, d0, fi, N);  m = frame(I{b}, d0, fi, N);
    if isempty(r) || isempty(m)
        fprintf('  %dx%d | %s / %s not found\n', XB{b,1}, XB{b,2}, XB{b,3}, XB{b,4});
        continue;
    end
    found(b) = true;  Xre(b,:) = r;  Xim(b,:) = m;
    a  = hypot(r, m);
    up = sum(abs(r(N/2+1:end))) + sum(abs(m(N/2+1:end)));
    kk = expK(b);  if isnan(kk), kk = K; end     % uncorrelated: report at the ref tone bin
    [pk, pb] = max(a);  pb = pb - 1;

    if expX(b) == 0
        ok  = max(a) <= 3;                       % rounding leaves at most +-1
        phM = NaN;  phE = NaN;
    else
        phM = rad2deg(atan2(m(kk+1), r(kk+1)));
        phE = rad2deg(angle(expX(b)));
        offPk = a;  offPk(kk+1) = 0;
        ok  = pb == kk && abs(wrapdeg(phM - phE)) < 2 && ...
              abs(a(kk+1)/abs(expX(b)) - 1) < 0.03 && max(offPk) <= 0.01*pk;
    end
    ok = ok && up == 0;
    summary(b,:) = [a(kk+1), abs(expX(b)), phM, phE];

    fprintf('  %dx%d | %8d | %8d | %5.0f | %10.0f | %5.1f | %6.1f | %8d | %5s | %s\n', ...
        XB{b,1}, XB{b,2}, r(kk+1), m(kk+1), a(kk+1), abs(expX(b)), phM, phE, pb, ...
        tern(up == 0, 'empty', 'FULL'), tern(ok, 'PASS', 'CHECK'));
end

% ---- Figure: Re and Im vs bin ----
figure('Name', 'Cross -- Real and Imag vs bin', 'Color', 'w');
for b = find(found).'
    subplot(3,2,b);
    stem(bins, Xre(b,:), 'b', 'Marker', 'none', 'LineWidth', 1.2); hold on;
    stem(bins, Xim(b,:), 'r', 'Marker', 'none', 'LineWidth', 1.2); hold off;
    grid on; xlim([0 N-1]);
    yl = max(abs([Xre(b,:) Xim(b,:)]));  if yl > 0, ylim(1.15*[-yl yl]); else, ylim([-1 1]); end
    title(sprintf('%d x %d -- Re (blue), Im (red)', XB{b,1}, XB{b,2}));
    xlabel('Bin'); ylabel('16-bit signed');
end

% ---- Figure: magnitude and phase vs frequency (positive half) ----
figure('Name', 'Cross -- Magnitude and Phase vs frequency', 'Color', 'w');
for b = find(found).'
    a  = hypot(Xre(b,pos+1), Xim(b,pos+1));
    ph = rad2deg(atan2(Xim(b,pos+1), Xre(b,pos+1)));
    ph(a < max(4, 0.01*max(a))) = NaN;          % phase of near-zero bins is meaningless
    subplot(nb,2,2*b-1);
    stem(fPos, a, 'filled', 'MarkerSize', 3); grid on; xlim([0 fPos(end)]);
    ylabel('|X|'); title(sprintf('%d x %d magnitude', XB{b,1}, XB{b,2}));
    subplot(nb,2,2*b);
    stem(fPos, ph, 'filled', 'MarkerSize', 3); grid on; xlim([0 fPos(end)]); ylim([-190 190]);
    yticks(-180:90:180); ylabel('deg'); title(sprintf('%d x %d phase', XB{b,1}, XB{b,2}));
end
subplot(nb,2,2*nb-1); xlabel('Frequency (MHz)');  subplot(nb,2,2*nb); xlabel('Frequency (MHz)');

% ---- Figure: summary, measured vs expected at the tone ----
figure('Name', 'Cross -- summary at tone bin', 'Color', 'w');
names = arrayfun(@(b) sprintf('%dx%d', XB{b,1}, XB{b,2}), 1:nb, 'UniformOutput', false);
subplot(1,2,1);
bar([summary(:,1) summary(:,2)]); grid on;
set(gca, 'XTickLabel', names); legend('measured', 'expected', 'Location', 'best');
ylabel('|X| at tone bin'); title('Cross magnitude');
subplot(1,2,2);
plot(1:nb, summary(:,3), 'bo', 'MarkerSize', 9, 'LineWidth', 1.5); hold on;
plot(1:nb, summary(:,4), 'rx', 'MarkerSize', 11, 'LineWidth', 1.5); hold off; grid on;
xlim([0.5 nb+0.5]); ylim([-190 190]); yticks(-180:90:180);
set(gca, 'XTick', 1:nb, 'XTickLabel', names);
legend('measured', 'expected', 'Location', 'best');
ylabel('Phase (deg)'); title('Cross phase (blank = uncorrelated pair)');

% ---- bit widths ----
bitsU = @(v) max(1, ceil(log2(double(v)+1)));
fprintf('\nBit use: auto peak %d needs %d of 16 bits (unsigned); cross |peak| %d needs %d of 16 (signed)\n', ...
    max(autoRes(:,2)), bitsU(max(autoRes(:,2))), ...
    max(abs([Xre(:); Xim(:)])), bitsU(max(abs([Xre(:); Xim(:)]))) + 1);

fprintf('\n====================================================================\n');


%% ===================== Local functions =====================
function d = local_getData(out, name)
    try, s = out.(name); catch, d = []; return; end
    if isa(s, 'Simulink.SimulationData.Signal'), d = s.Values.Data;
    elseif isa(s, 'timeseries'),                 d = s.Data;
    elseif isstruct(s) && isfield(s, 'signals'), d = s.signals.values;
    elseif isnumeric(s),                         d = s;
    else,                                        d = [];
    end
    if ~isempty(d), d = double(d(:)); end
end

function f = frame(x, d0, fi, N)
    f = [];
    if isempty(x), return; end
    nf = floor((numel(x) - d0)/N);
    if fi > nf, return; end
    f = x(d0 + (fi-1)*N + (1:N)).';
end

function [up, w] = pulses(v)
    e  = diff([0; v(:) > 0; 0]);
    up = find(e == 1);  w = find(e == -1) - up;
end

function a = wrapdeg(a), a = mod(a + 180, 360) - 180; end
function o = tern(c, a, b), if c, o = a; else, o = b; end, end

function spec = local_align(out, sigName, N, Fs, expectedBin)
% Self-alignment for auto signals (unchanged from final_code.m).
    spec = [];
    stream = local_getData(out, sigName);
    if isempty(stream)
        fprintf('   %-16s : NOT FOUND in "out"\n', sigName);  return;
    end
    if numel(stream) < 2*N
        fprintf('   %-16s : only %d samples (raise Stop Time)\n', sigName, numel(stream));  return;
    end
    [gmax, p] = max(abs(stream));
    if gmax <= 0
        fprintf('   %-16s : all zero\n', sigName);  spec = stream(1:N).';  return;
    end
    kk = 2:(N/2);  mi = N - (kk-1) + 1;
    upper = (N/2+2):N;
    specs = cell(1,N);  symErr = nan(1,N);  upEnrgy = nan(1,N);  toneVal = nan(1,N);
    for b = 0:N-1
        d0 = mod(p - b - 1, N);
        nf = floor((numel(stream)-d0)/N);
        if nf < 1, continue; end
        F = reshape(stream(d0+1 : d0+nf*N), N, nf);
        [~, fi] = max(max(abs(F), [], 1));
        s = F(:,fi).';
        specs{b+1}   = s;
        symErr(b+1)  = sum(abs(s(kk) - s(mi)));
        upEnrgy(b+1) = sum(abs(s(upper)));
        toneVal(b+1) = abs(s(expectedBin+1));
    end
    gated = upEnrgy <= 1e-6*gmax;
    if any(gated)
        cand = find(gated);  [~, j] = max(toneVal(cand));  idx = cand(j);
    else
        tol  = min(symErr(~isnan(symErr))) + 0.01*gmax;
        cand = find(symErr <= tol);
        score = min(abs((cand-1) - expectedBin), abs((cand-1) - (N - expectedBin)));
        [~, ord] = sort(score);  cand = cand(ord);  idx = cand(1);
        for t = cand
            [~, pk] = max(abs(specs{t}));
            if (pk-1) == expectedBin || (pk-1) == (N - expectedBin), idx = t; break; end
        end
    end
    spec = specs{idx};
end