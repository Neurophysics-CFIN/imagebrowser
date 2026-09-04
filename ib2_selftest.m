function results = ib2_selftest()
%IB2_SELFTEST  Run the ImageBrowserApp self test.
%
%   IB2_SELFTEST() builds several browsers on synthetic data, drives
%   navigation, colour mapping, montage, cine, ROIs, curve extraction,
%   overlay and the export paths, prints a PASS/FAIL line per check and
%   closes the windows again.
%
%   RESULTS = IB2_SELFTEST() also returns the outcome as a table, so it can
%   be used in a larger test harness:
%
%       r = ib2_selftest();
%       assert(all(r.Passed), 'ImageBrowser self test failed.');
%
%   The test opens and closes real figures, so it needs a display.

    fprintf('ImageBrowser self test, MATLAB %s\n', version('-release'));
    if isempty(which('drawpolygon'))
        fprintf(['NOTE: Image Processing Toolbox was not found. Interactive ROI\n' ...
                 '      drawing is unavailable; the mask-based paths are still tested.\n']);
    end
    fprintf('%s\n', repmat('-', 1, 56));

    results = ImageBrowserApp.selftest(true);

    if nargout == 0
        failed = results(~results.Passed, :);
        if ~isempty(failed)
            disp(failed);
        end
        clear results
    end
end
