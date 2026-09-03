function varargout = imagebrowser2(varargin)
%IMAGEBROWSER2  Browse series of images, define ROIs and plot signal curves.
%
%   IMAGEBROWSER2(DATA) opens the browser on DATA.  Dimensions 1 and 2 are
%   the image; dimensions 3 and beyond are navigable with sliders, the arrow
%   keys, the scroll wheel or the cine button.  DATA may be a numeric or
%   logical array of any dimensionality, a cell array (one series per cell),
%   or a struct (one series per field).
%
%   IMAGEBROWSER2(DATA, MASK) additionally loads a logical ROI mask.  MASK is
%   either a single 2-D mask or a stack with one mask per frame.  This
%   reproduces the two-argument call of the original IMAGEBROWSER.
%
%   IMAGEBROWSER2(SIZEVEC, PRECISION) reads a headerless Bruker 2dseq file
%   named "2dseq" in the current folder, e.g.
%       imagebrowser2([128 128 30 163], 'int16')
%   This too is kept for compatibility with the original.
%
%   IMAGEBROWSER2(DATA, Name=Value, ...) accepts the options
%       Name         window title
%       SeriesNames  names for the supplied series
%       DimNames     names for the navigable dimensions, e.g. ["slice" "b"]
%       Colormap     initial colormap, default "gray"
%       CLim         initial colour limits
%       XData        x values for the signal plot, e.g. b-values or echo times
%       XLabel       x-axis label for the signal plot
%       Overlay      second dataset drawn on top with alpha blending
%       ROI          initial logical mask
%       Theme        "system" (default), "light" or "dark"
%       RGB          true to read dimension 3 as colour
%
%   APP = IMAGEBROWSER2(...) returns the ImageBrowserApp object, so the
%   browser can be driven from the command line:
%       app = imagebrowser2(vol);
%       app.Frame = 12;
%       app.Colormap = "turbo";
%       T = app.roiStats();
%
%   Example
%       vol = rand(96, 96, 20, 8);
%       b   = [0 100 300 600 1000 1500 2000 3000];
%       imagebrowser2(vol, DimNames=["slice" "b-value"], XData=b, ...
%                     XLabel="b (s/mm^2)", Colormap="gray");
%
%   See also ImageBrowserApp.

%   This is a from-scratch modernisation of the GUIDE-era imagebrowser.
%   The original files are left untouched.

    optionNames = ["Name" "SeriesNames" "DimNames" "Colormap" "CLim" ...
                   "XData" "XLabel" "Overlay" "ROI" "Theme" "RGB"];

    data = [];
    nvStart = 1;

    if nargin >= 1
        data = varargin{1};
        nvStart = 2;
    end

    extra = {};

    if nargin >= 2
        second = varargin{2};
        isOptionName = (ischar(second) || (isstring(second) && isscalar(second))) && ...
                       any(strcmpi(string(second), optionNames));

        if ~isOptionName && (ischar(second) || (isstring(second) && isscalar(second)))
            % Legacy form: imagebrowser2(SIZEVEC, PRECISION) reading ./2dseq
            if isnumeric(data) && isvector(data) && numel(data) >= 2 && ...
                    all(data == round(data)) && all(data > 0) && ...
                    exist(fullfile(pwd, '2dseq'), 'file') == 2
                data = ImageBrowserApp.read2dseq(fullfile(pwd, '2dseq'), ...
                    data(:)', char(second));
                nvStart = 3;
            else
                error('imagebrowser2:badInput', ...
                    ['A second character argument is read as a binary precision ' ...
                     'for a Bruker 2dseq file, but no file named "2dseq" was found ' ...
                     'in the current folder (or the first argument is not a size ' ...
                     'vector).']);
            end

        elseif ~isOptionName && (islogical(second) || isnumeric(second))
            % Legacy form: imagebrowser2(DATA, MASK)
            extra = {'ROI', logical(second)};
            nvStart = 3;
        end
    end

    % Whatever is left must be name-value pairs. Checking here reports the
    % problem against imagebrowser2 rather than against ImageBrowserApp's
    % arguments block, which is what the caller actually typed.
    nv = varargin(nvStart:end);
    if mod(numel(nv), 2) ~= 0
        error('imagebrowser2:badOptions', ...
            ['Options must be given as name-value pairs; %d trailing ' ...
             'argument(s) found. Type "help imagebrowser2" for the list.'], ...
            numel(nv));
    end
    for k = 1:2:numel(nv)
        if ~(ischar(nv{k}) || (isstring(nv{k}) && isscalar(nv{k})))
            error('imagebrowser2:badOptionName', ...
                'Argument %d should be an option name but is of class %s.', ...
                nvStart + k - 1, class(nv{k}));
        end
    end

    app = ImageBrowserApp(data, extra{:}, nv{:});

    if nargout > 0
        varargout{1} = app;
    end
end
