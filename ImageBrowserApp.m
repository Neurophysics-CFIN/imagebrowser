classdef ImageBrowserApp < handle
    %IMAGEBROWSERAPP  Interactive browser for series of images (MRI and general).
    %
    %   Modern replacement for the GUIDE-era IMAGEBROWSER.  Use the wrapper
    %   function IMAGEBROWSER2 to launch it; this class can also be constructed
    %   directly:
    %
    %       app = ImageBrowserApp(DATA)
    %       app = ImageBrowserApp(DATA, Name=Value, ...)
    %
    %   DATA may be
    %     * a numeric or logical array of any dimensionality.  Dimensions 1 and
    %       2 are the image; dimensions 3..N are navigable (slice, volume, ...).
    %     * a cell array, in which case each element becomes its own series.
    %     * a struct, in which case each field becomes its own series named
    %       after the field.
    %
    %   Name-value options
    %     Name        (string)  window title
    %     SeriesNames (string array or cellstr) names for the supplied series
    %     DimNames    (string array) names for the navigable dimensions
    %     Colormap    (char/string/Mx3) initial colormap, default "gray"
    %     CLim        (1x2) initial colour limits
    %     XData       (vector) x-axis values for the signal plot, e.g. b-values
    %     XLabel      (string) x-axis label for the signal plot
    %     Overlay     (array)  second dataset displayed on top with alpha blending
    %     ROI         (logical) initial ROI mask, 2-D or matching the frame count
    %     Theme       "system" | "light" | "dark"
    %     RGB         (logical) interpret dimension 3 as colour, default auto
    %
    %   Keyboard
    %     Left/Right      previous / next frame          Space   play / pause cine
    %     PageUp/PageDown +/- 10 frames                  Home/End first / last frame
    %     Up/Down         previous / next series         C       toggle colorbar
    %     +/-             more / less contrast           L       lock colour limits
    %     R               reset colour limits            M       toggle montage
    %     Scroll wheel    change frame            Ctrl+scroll     zoom about cursor
    %     Right-drag      window/level (brightness/contrast)
    %
    %   See also IMAGEBROWSER2.

    %   Written as a from-scratch modernisation of imagebrowser.m
    %   (Daniel Otykier et al.).  Requires R2023b or newer; the ROI drawing
    %   tools additionally require Image Processing Toolbox.

    %======================================================================
    % Public state
    %======================================================================
    properties (Dependent)
        Frame       % linear frame index within the current series
        CLim        % current colour limits [lo hi]
        Colormap    % current colormap (name or Mx3)
    end

    properties
        XData    (1,:) double = []      % x values for the signal plot
        XLabel   (1,1) string = "Frame" % x label for the signal plot
    end

    properties (SetAccess = private)
        Series      struct = ImageBrowserApp.emptySeries()  % the loaded data
        SeriesIndex (1,1) double = 1                        % active series
        Sub   (1,:) double = []                             % subscripts into navigable dims
        ROIs        struct = ImageBrowserApp.emptyROI()     % all stored ROIs
    end

    %======================================================================
    % Private state
    %======================================================================
    properties (Access = private)
        UI          struct = struct()   % all graphics handles
        Overlay     struct = struct('Data',[],'CLim',[0 1],'Colormap',"hot", ...
            'Alpha',0.5,'Threshold',-Inf,'Enabled',false)
        CLimStore   (1,2) double = [0 1]
        CLimLock    (1,1) logical = false
        CLimMode    (1,1) string  = "minmax"   % "minmax" | "robust" | "manual"
        RobustPct   (1,1) double  = 1          % percent clipped at each end
        CmapName    (1,1) string  = "gray"
        CmapInvert  (1,1) logical = false
        ActiveLayer (1,1) string  = "base"     % which layer W/L acts on
        ShowAllROIs (1,1) logical = false      % "sticky" ROIs
        LiveROIs    (1,:) cell = {}            % images.roi objects on screen
        LiveROIIdx  (1,:) double = []          % record index for each live object
        ROIListeners(1,:) cell = {}
        OutlineH    = gobjects(1,0)
        MontageOn   (1,1) logical = false
        MontageMap  = []                       % frame index per montage tile
        CineTimer   = []
        CineFPS     (1,1) double = 10
        PixelSurf   (1,1) logical = false
        PlotMode    (1,1) string  = "pixel"    % "pixel" | "roi"
        SweepDim    (1,1) double = 0           % 0 = across series, k = navigable dim k
        PlotRange   (1,2) double = [1 1]
        LastPixel   (1,2) double = [NaN NaN]
        WLDrag      struct = struct('Active',false,'Origin',[0 0],'CLim',[0 1])
        ModCtrl     (1,1) logical = false
        FunSpec     struct = struct('Fun',[],'X',[],'Par',[])   % user function overlay
        FitResult   struct = struct()                           % last DTI/DKI fit
        HasIPT      (1,1) logical = false
        Closing     (1,1) logical = false
        ThemeChoice (1,1) string = "system"
        ROIColors   (:,3) double = lines(12)
        ROIsDirty   (1,1) logical = false       % ROIs changed since last export
        RoiLines    = gobjects(1,0)             % one plotted curve per ROI
    end

    properties (Constant, Access = private)
        SidebarWidth = 320
        PlotHeight   = 210
        AppVersion   = "3.0"
    end

    %======================================================================
    % Construction / destruction
    %======================================================================
    methods
        function app = ImageBrowserApp(data, opts)
            arguments
                data = []
                opts.Name        (1,1) string = "Image Browser"
                opts.SeriesNames = string.empty
                opts.DimNames    = string.empty
                opts.Colormap    = "gray"
                opts.CLim        double = []
                opts.XData       (1,:) double = []
                opts.XLabel      (1,1) string = "Frame"
                opts.Overlay     = []
                opts.ROI         = []
                opts.Theme       (1,1) string = "system"
                opts.RGB         = []
            end

            app.HasIPT = ~isempty(which('drawpolygon'));
            app.ThemeChoice = opts.Theme;
            app.XData  = opts.XData;
            app.XLabel = opts.XLabel;

            app.buildUI(opts.Name);

            if isempty(data)
                app.addSeries(ImageBrowserApp.splashImage(), "Image Browser " + app.AppVersion);
                app.Series(1).IsRGB = true;
            else
                app.addSeries(data, opts.SeriesNames, opts.RGB);
            end
            if ~isempty(opts.DimNames) && ~isempty(app.Series)
                n = numel(app.Series(app.SeriesIndex).DimNames);
                dn = string(opts.DimNames);
                app.Series(app.SeriesIndex).DimNames(1:min(n,numel(dn))) = dn(1:min(n,numel(dn)));
            end

            if ~isempty(opts.Overlay)
                app.setOverlay(opts.Overlay);
            end
            if ~isempty(opts.ROI)
                app.importROIData(opts.ROI, "imported");
            end

            app.selectSeries(1);
            if ~isempty(opts.CLim)
                app.CLimMode = "manual";
                app.setCLim(opts.CLim);
            end
            app.setXLabel(opts.XLabel);
            if ischar(opts.Colormap) || isstring(opts.Colormap)
                app.setColormap(opts.Colormap);
            end
            app.applyTheme();
            app.UI.Fig.Visible = "on";
            drawnow limitrate
        end

        function delete(app)
            app.Closing = true;
            app.stopCine();
            if isfield(app.UI,'Fig') && isvalid(app.UI.Fig)
                delete(app.UI.Fig);
            end
        end
    end

    %======================================================================
    % Dependent property access
    %======================================================================
    methods
        function v = get.Frame(app)
            v = app.frameLinear();
        end
        function set.Frame(app, v)
            app.gotoFrame(v);
        end
        function v = get.CLim(app)
            v = app.CLimStore;
        end
        function set.CLim(app, v)
            app.CLimMode = "manual";
            app.setCLim(v);
        end
        function v = get.Colormap(app)
            v = app.CmapName;
        end
        function set.Colormap(app, v)
            app.setColormap(v);
        end
    end

    %======================================================================
    % Public API
    %======================================================================
    methods
        function addSeries(app, data, names, isRGB)
            %ADDSERIES  Append one or more series to the browser.
            if nargin < 3, names = string.empty; end
            if nargin < 4, isRGB = []; end
            n0 = numel(app.Series);
            app.Series = [app.Series, ImageBrowserApp.buildSeries(data, names, isRGB)];
            if numel(app.Series) > n0
                app.refreshSeriesList();
                if n0 == 0
                    app.selectSeries(1);
                else
                    app.refreshAll();
                end
            end
        end

        function removeSeries(app, idx)
            %REMOVESERIES  Delete series by index.
            idx = idx(idx >= 1 & idx <= numel(app.Series));
            if isempty(idx), return; end
            keep = setdiff(1:numel(app.Series), idx);
            app.ROIs(ismember([app.ROIs.Series], idx)) = [];
            remap = zeros(1, numel(app.Series));
            remap(keep) = 1:numel(keep);
            for k = 1:numel(app.ROIs)
                app.ROIs(k).Series = remap(app.ROIs(k).Series);
            end
            app.Series = app.Series(keep);
            app.refreshSeriesList();
            app.selectSeries(min(app.SeriesIndex, max(1,numel(app.Series))));
        end

        function setOverlay(app, data, opts)
            %SETOVERLAY  Display a second dataset blended over the base image.
            arguments
                app
                data = []
                opts.Colormap  = "hot"
                opts.Alpha     (1,1) double = 0.5
                opts.CLim      double = []
                opts.Threshold (1,1) double = -Inf
            end
            if isempty(data)
                app.Overlay.Enabled = false;
                app.Overlay.Data = [];
            else
                app.Overlay.Data      = double(data);
                app.Overlay.Colormap  = opts.Colormap;
                app.Overlay.Alpha     = opts.Alpha;
                app.Overlay.Threshold = opts.Threshold;
                if isempty(opts.CLim)
                    app.Overlay.CLim = ImageBrowserApp.safeLimits(app.Overlay.Data);
                else
                    app.Overlay.CLim = opts.CLim;
                end
                app.Overlay.Enabled = true;
            end
            app.syncOverlayControls();
            app.refreshAll();
        end

        function T = roiStats(app, scope)
            %ROISTATS  Table of statistics for stored ROIs.
            %   T = roiStats(app)          statistics for every stored ROI
            %   T = roiStats(app,"frame")  only the ROIs on the current frame
            if nargin < 2, scope = "all"; end
            sel = 1:numel(app.ROIs);
            if scope == "frame"
                sel = app.roisOnCurrentFrame();
            end
            n = numel(sel);
            [Series, Frame, Npix, Mean, SD, Minv, Maxv, Median] = deal(zeros(n,1));
            [Name, SeriesName, Shape] = deal(strings(n,1));
            for i = 1:n
                r = app.ROIs(sel(i));
                img = app.imageAt(r.Series, r.Frame);
                s = ImageBrowserApp.maskStats(img, r.Mask);
                Series(i) = r.Series;  Frame(i) = r.Frame;
                SeriesName(i) = app.Series(r.Series).Name;
                Name(i) = r.Name;      Shape(i) = r.Shape;
                Npix(i) = s.N;  Mean(i) = s.Mean;  SD(i) = s.SD;
                Minv(i) = s.Min; Maxv(i) = s.Max;  Median(i) = s.Median;
            end
            T = table(Series, SeriesName, Frame, Name, Shape, Npix, Mean, SD, ...
                Minv, Maxv, Median);
            T.Properties.VariableNames{9}  = 'Min';
            T.Properties.VariableNames{10} = 'Max';
        end

        function m = getROIMask(app, combine)
            %GETROIMASK  Logical mask of the current frame's visible ROIs.
            if nargin < 2, combine = true; end
            sel = app.roisOnCurrentFrame();
            img = app.currentImage();
            m = false(size(img,1), size(img,2));
            if isempty(sel), return; end
            if combine
                for i = sel
                    m = m | app.ROIs(i).Mask;
                end
            else
                m = false(size(img,1), size(img,2), numel(sel));
                for k = 1:numel(sel)
                    m(:,:,k) = app.ROIs(sel(k)).Mask;
                end
            end
        end

        function figHandle = getFigure(app)
            %GETFIGURE  Handle of the underlying uifigure.
            figHandle = app.UI.Fig;
        end
    end

    %======================================================================
    % User interface construction
    %======================================================================
    methods (Access = private)

        function buildUI(app, titleStr)
            app.UI.Fig = uifigure('Name', titleStr, 'Visible', 'off', ...
                'Position', [100 100 1180 760]);
            app.UI.Fig.CloseRequestFcn      = @(~,~) app.onClose();
            app.UI.Fig.WindowButtonMotionFcn= @(~,~) app.onMouseMove();
            app.UI.Fig.WindowButtonDownFcn  = @(s,e) app.onMouseDown(e);
            app.UI.Fig.WindowButtonUpFcn    = @(~,~) app.onMouseUp();
            app.UI.Fig.WindowScrollWheelFcn = @(~,e) app.onScroll(e);
            app.UI.Fig.WindowKeyPressFcn    = @(~,e) app.onKey(e);

            app.buildMenus();

            root = uigridlayout(app.UI.Fig, [1 2]);
            root.ColumnWidth = {'1x', app.SidebarWidth};
            root.RowHeight   = {'1x'};
            root.Padding     = [6 6 6 6];
            root.ColumnSpacing = 6;
            app.UI.Root = root;

            % ---------------- left column ----------------------------------
            left = uigridlayout(root, [5 1]);
            left.Layout.Row = 1; left.Layout.Column = 1;
            left.RowHeight = {'fit', '1x', 'fit', 'fit', 0};
            left.Padding = [0 0 0 0];
            left.RowSpacing = 4;
            app.UI.Left = left;

            app.buildDisplayBar(left);

            ax = uiaxes(left);
            ax.Layout.Row = 2; ax.Layout.Column = 1;
            ax.XTick = []; ax.YTick = [];
            ax.YDir = 'reverse';
            ax.DataAspectRatio = [1 1 1];
            ax.Box = 'on';
            ax.Interactions = [];
            ax.Toolbar = axtoolbar(ax, {'export','restoreview'});
            hold(ax, 'on');
            app.UI.Axes = ax;

            app.UI.Image = image(ax, 'CData', zeros(2,2), 'CDataMapping', 'scaled');
            app.UI.OverlayImage = image(ax, 'CData', zeros(2,2), ...
                'CDataMapping', 'direct', 'Visible', 'off');
            app.UI.CBar = colorbar(ax);
            app.UI.CBar.Visible = 'off';

            app.buildNavBar(left);

            st = uilabel(left, 'Text', 'Move the pointer over the image for pixel info.');
            st.Layout.Row = 4; st.Layout.Column = 1;
            st.HorizontalAlignment = 'left';
            st.FontName = 'Consolas';
            app.UI.Status = st;

            app.buildPlotPanel(left);

            % ---------------- right column ---------------------------------
            tg = uitabgroup(root);
            tg.Layout.Row = 1; tg.Layout.Column = 2;
            app.UI.Tabs = tg;
            app.buildSeriesTab(uitab(tg, 'Title', 'Series'));
            app.buildROITab(uitab(tg, 'Title', 'ROI'));
            app.buildDisplayTab(uitab(tg, 'Title', 'Display'));
            app.buildAnalysisTab(uitab(tg, 'Title', 'Analysis'));
        end

        %------------------------------------------------------------------
        function buildMenus(app)
            f = app.UI.Fig;

            m = uimenu(f, 'Text', '&File');
            mi = uimenu(m, 'Text', '&Import');
            uimenu(mi, 'Text', 'Image from &workspace...', 'MenuSelectedFcn', @(~,~) app.uiImportImage());
            uimenu(mi, 'Text', '&ROI from workspace...',   'MenuSelectedFcn', @(~,~) app.uiImportROI());
            uimenu(mi, 'Text', 'Image from &file...',      'MenuSelectedFcn', @(~,~) app.uiImportFile());
            uimenu(mi, 'Text', 'Bruker &2dseq...',         'MenuSelectedFcn', @(~,~) app.uiImport2dseq());
            me = uimenu(m, 'Text', 'E&xport');
            uimenu(me, 'Text', 'Current &image to file...',   'MenuSelectedFcn', @(~,~) app.uiExportImage());
            uimenu(me, 'Text', 'Current image to &workspace...', 'MenuSelectedFcn', @(~,~) app.uiExportImageToWS());
            uimenu(me, 'Text', 'App &snapshot to file...',    'MenuSelectedFcn', @(~,~) app.uiExportApp());
            uimenu(me, 'Text', '&Cine to GIF / MP4...', 'Separator','on', 'MenuSelectedFcn', @(~,~) app.uiExportCine());
            uimenu(me, 'Text', 'ROI &mask to workspace...', 'Separator','on', 'MenuSelectedFcn', @(~,~) app.uiExportROIMask());
            uimenu(me, 'Text', 'ROI se&quence to workspace...', 'MenuSelectedFcn', @(~,~) app.uiExportROISeq());
            uimenu(me, 'Text', 'ROI &statistics to workspace...', 'MenuSelectedFcn', @(~,~) app.uiExportROIStatsWS());
            uimenu(me, 'Text', 'ROI statistics to C&SV...', 'MenuSelectedFcn', @(~,~) app.uiExportROIStatsCSV());
            uimenu(m, 'Text', '&Close', 'Separator', 'on', 'Accelerator', 'W', ...
                'MenuSelectedFcn', @(~,~) app.onClose());

            m = uimenu(f, 'Text', '&View');
            app.UI.MenuColorbar = uimenu(m, 'Text', '&Colorbar', 'Accelerator', 'B', ...
                'MenuSelectedFcn', @(~,~) app.toggleColorbar());
            app.UI.MenuMontage = uimenu(m, 'Text', '&Montage', ...
                'MenuSelectedFcn', @(~,~) app.toggleMontage());
            app.UI.MenuPlotPanel = uimenu(m, 'Text', 'Signal &plot panel', ...
                'MenuSelectedFcn', @(~,~) app.togglePlotPanel());
            uimenu(m, 'Text', '&Reset zoom', 'Separator', 'on', ...
                'MenuSelectedFcn', @(~,~) app.resetView());
            mt = uimenu(m, 'Text', '&Theme', 'Separator', 'on');
            app.UI.MenuTheme = gobjects(1,3);
            names = ["System" "Light" "Dark"]; vals = ["system" "light" "dark"];
            for k = 1:3
                app.UI.MenuTheme(k) = uimenu(mt, 'Text', names(k), ...
                    'MenuSelectedFcn', @(~,~) app.setTheme(vals(k)));
            end

            m = uimenu(f, 'Text', 'Colo&rmap');
            uimenu(m, 'Text', '&Modify limits...', 'Accelerator', 'M', ...
                'MenuSelectedFcn', @(~,~) app.uiModifyCLim());
            uimenu(m, 'Text', '&Reset limits', 'Accelerator', 'E', ...
                'MenuSelectedFcn', @(~,~) app.resetCLim());
            uimenu(m, 'Text', '&Auto (robust)', ...
                'MenuSelectedFcn', @(~,~) app.setCLimMode("robust"));
            app.UI.MenuLock = uimenu(m, 'Text', '&Lock limits', 'Accelerator', 'L', ...
                'MenuSelectedFcn', @(~,~) app.toggleCLimLock());
            mc = uimenu(m, 'Text', '&Choose', 'Separator', 'on');
            for nm = ImageBrowserApp.colormapNames()
                uimenu(mc, 'Text', nm, 'MenuSelectedFcn', @(s,~) app.setColormap(string(s.Text)));
            end
            app.UI.MenuInvert = uimenu(m, 'Text', '&Invert colormap', ...
                'MenuSelectedFcn', @(~,~) app.toggleInvert());

            m = uimenu(f, 'Text', 'R&OI');
            shapes = ["Polygon" "Freehand" "Ellipse" "Rectangle" "Circle" "Point"];
            mn = uimenu(m, 'Text', '&New');
            for s = shapes
                uimenu(mn, 'Text', s, 'MenuSelectedFcn', @(o,~) app.newROI(string(o.Text)));
            end
            uimenu(m, 'Text', '&Auto ROI by threshold...', 'Accelerator', 'R', ...
                'MenuSelectedFcn', @(~,~) app.uiAutoROI());
            uimenu(m, 'Text', '&Delete selected', 'Separator', 'on', ...
                'MenuSelectedFcn', @(~,~) app.deleteSelectedROIs());
            uimenu(m, 'Text', 'Delete all on this &frame', ...
                'MenuSelectedFcn', @(~,~) app.deleteFrameROIs());
            uimenu(m, 'Text', 'Delete all in this &series', ...
                'MenuSelectedFcn', @(~,~) app.deleteSeriesROIs());
            uimenu(m, 'Text', '&Copy selected to frames...', 'Separator', 'on', ...
                'Accelerator', 'S', 'MenuSelectedFcn', @(~,~) app.uiCopyROIToFrames());
            app.UI.MenuSticky = uimenu(m, 'Text', 'Show ROIs from all &frames', ...
                'Accelerator', 'D', 'MenuSelectedFcn', @(~,~) app.toggleShowAllROIs());

            m = uimenu(f, 'Text', '&Analysis');
            app.UI.MenuPixelSurf = uimenu(m, 'Text', '&Pixel surfing', ...
                'MenuSelectedFcn', @(~,~) app.togglePixelSurf());
            uimenu(m, 'Text', 'Plot &ROI mean over sweep', ...
                'MenuSelectedFcn', @(~,~) app.plotROICurve());
            uimenu(m, 'Text', 'Set &x-axis from workspace...', 'Separator', 'on', ...
                'MenuSelectedFcn', @(~,~) app.uiSetXData());
            uimenu(m, 'Text', '&Clear custom x-axis', ...
                'MenuSelectedFcn', @(~,~) app.clearXData());
            uimenu(m, 'Text', 'Fit &DTI / DKI to this curve...', 'Separator', 'on', ...
                'MenuSelectedFcn', @(~,~) app.uiFitDiffusion());
            uimenu(m, 'Text', 'Clear &fit', ...
                'MenuSelectedFcn', @(~,~) app.clearFit());
            uimenu(m, 'Text', 'Export fit result to &workspace...', ...
                'MenuSelectedFcn', @(~,~) app.uiExportFit());
            uimenu(m, 'Text', 'Plot a f&unction...', 'Separator', 'on', ...
                'MenuSelectedFcn', @(~,~) app.uiPlotFunction());
            uimenu(m, 'Text', 'Clear plotted f&unction', ...
                'MenuSelectedFcn', @(~,~) app.clearPlottedFunction());
            uimenu(m, 'Text', '&Export plot data...', 'Separator', 'on', ...
                'MenuSelectedFcn', @(~,~) app.uiExportPlotData());

            m = uimenu(f, 'Text', '&Help');
            uimenu(m, 'Text', '&Keyboard shortcuts', 'MenuSelectedFcn', @(~,~) app.showShortcuts());
            uimenu(m, 'Text', '&About', 'MenuSelectedFcn', @(~,~) app.showAbout());
        end

        %------------------------------------------------------------------
        function buildDisplayBar(app, parent)
            g = uigridlayout(parent, [1 7]);
            g.Layout.Row = 1; g.Layout.Column = 1;
            g.ColumnWidth = {90, 90, 90, 90, 90, 90, '1x'};
            g.RowHeight = {26};
            g.Padding = [0 0 0 0];
            g.ColumnSpacing = 4;

            app.UI.BtnColorbar = uibutton(g, 'state', 'Text', 'Colorbar', ...
                'Tooltip', 'Show the colour bar (C)', ...
                'ValueChangedFcn', @(s,~) app.setColorbar(s.Value));
            app.UI.BtnAuto = uibutton(g, 'push', 'Text', 'Auto W/L', ...
                'Tooltip', 'Robust automatic window/level (percentile clipping)', ...
                'ButtonPushedFcn', @(~,~) app.setCLimMode("robust"));
            app.UI.BtnResetW = uibutton(g, 'push', 'Text', 'Full range', ...
                'Tooltip', 'Reset colour limits to the data min/max (R)', ...
                'ButtonPushedFcn', @(~,~) app.resetCLim());
            app.UI.BtnLock = uibutton(g, 'state', 'Text', 'Lock W/L', ...
                'Tooltip', 'Keep the colour limits fixed when changing frame (L)', ...
                'ValueChangedFcn', @(s,~) app.setCLimLock(s.Value));
            app.UI.BtnMontage = uibutton(g, 'state', 'Text', 'Montage', ...
                'Tooltip', 'Tile every frame of this series (M)', ...
                'ValueChangedFcn', @(s,~) app.setMontage(s.Value));
            app.UI.BtnPlotPanel = uibutton(g, 'state', 'Text', 'Plot', ...
                'Tooltip', 'Show the signal plot panel', ...
                'ValueChangedFcn', @(s,~) app.setPlotPanel(s.Value));
        end

        %------------------------------------------------------------------
        function buildNavBar(app, parent)
            g = uigridlayout(parent, [5 1]);
            g.Layout.Row = 3; g.Layout.Column = 1;
            g.RowHeight = {0, 0, 0, 0, 32};
            g.Padding = [0 0 0 0];
            g.RowSpacing = 2;
            app.UI.Nav = g;

            app.UI.NavRow = gobjects(1,4);
            app.UI.NavLabel = gobjects(1,4);
            app.UI.NavSlider = gobjects(1,4);
            app.UI.NavSpin = gobjects(1,4);
            app.UI.NavMax = gobjects(1,4);
            for k = 1:4
                r = uigridlayout(g, [1 4]);
                r.Layout.Row = k; r.Layout.Column = 1;
                r.ColumnWidth = {90, '1x', 70, 60};
                r.RowHeight = {30};
                r.Padding = [0 0 0 0]; r.ColumnSpacing = 6;
                r.Visible = 'off';
                app.UI.NavRow(k) = r;
                app.UI.NavLabel(k) = uilabel(r, 'Text', '', 'HorizontalAlignment', 'right');
                sl = uislider(r, 'Limits', [1 2], 'Value', 1, ...
                    'MajorTicks', [], 'MinorTicks', []);
                sl.ValueChangingFcn = @(s,e) app.onNavSlider(k, e.Value);
                sl.ValueChangedFcn  = @(s,e) app.onNavSlider(k, s.Value);
                app.UI.NavSlider(k) = sl;
                sp = uispinner(r, 'Limits', [1 2], 'Value', 1, 'Step', 1, ...
                    'RoundFractionalValues', 'on', 'ValueDisplayFormat', '%d');
                sp.ValueChangedFcn = @(s,~) app.onNavSlider(k, s.Value);
                app.UI.NavSpin(k) = sp;
                app.UI.NavMax(k) = uilabel(r, 'Text', '/ 1');
            end

            t = uigridlayout(g, [1 8]);
            t.Layout.Row = 5; t.Layout.Column = 1;
            t.ColumnWidth = {36, 36, 70, 36, 36, 70, 60, '1x'};
            t.RowHeight = {26};
            t.Padding = [0 0 0 0]; t.ColumnSpacing = 4;
            uibutton(t, 'push', 'Text', '|<', 'Tooltip', 'First frame (Home)', ...
                'ButtonPushedFcn', @(~,~) app.gotoFrame(1));
            uibutton(t, 'push', 'Text', '<', 'Tooltip', 'Previous frame (Left arrow)', ...
                'ButtonPushedFcn', @(~,~) app.stepFrame(-1));
            app.UI.BtnPlay = uibutton(t, 'state', 'Text', 'Play', ...
                'Tooltip', 'Cine through the series (Space)', ...
                'ValueChangedFcn', @(s,~) app.setCine(s.Value));
            uibutton(t, 'push', 'Text', '>', 'Tooltip', 'Next frame (Right arrow)', ...
                'ButtonPushedFcn', @(~,~) app.stepFrame(1));
            uibutton(t, 'push', 'Text', '>|', 'Tooltip', 'Last frame (End)', ...
                'ButtonPushedFcn', @(~,~) app.gotoFrame(app.frameCount()));
            app.UI.FPS = uispinner(t, 'Limits', [1 60], 'Value', 10, 'Step', 1, ...
                'ValueDisplayFormat', '%d fps', 'Tooltip', 'Cine frame rate', ...
                'ValueChangedFcn', @(s,~) app.setFPS(s.Value));
            app.UI.CineDim = uidropdown(t, 'Items', {'dim 1'}, 'ItemsData', 1, ...
                'Tooltip', 'Dimension the cine and the arrow keys step through', ...
                'ValueChangedFcn', @(~,~) app.refreshStatus());
        end

        %------------------------------------------------------------------
        function buildPlotPanel(app, parent)
            p = uipanel(parent, 'Title', 'Signal plot', 'Visible', 'off');
            p.Layout.Row = 5; p.Layout.Column = 1;
            app.UI.PlotPanel = p;
            g = uigridlayout(p, [1 1]);
            g.Padding = [4 4 4 4];
            ax = uiaxes(g);
            ax.Layout.Row = 1; ax.Layout.Column = 1;
            ax.XGrid = 'on'; ax.YGrid = 'on';
            xlabel(ax, 'Frame'); ylabel(ax, 'Signal');
            hold(ax, 'on');
            app.UI.PlotAxes = ax;
            app.UI.PlotLine = plot(ax, NaN, NaN, 'o-', 'LineWidth', 1.2, ...
                'MarkerSize', 4, 'DisplayName', 'signal');
            app.UI.PlotBand = patch(ax, 'XData', NaN, 'YData', NaN, ...
                'FaceColor', [0.3 0.5 0.9], 'FaceAlpha', 0.18, ...
                'EdgeColor', 'none', 'DisplayName', 'SD');
            app.UI.PlotFit  = plot(ax, NaN, NaN, '-', 'LineWidth', 1.8, ...
                'Color', [0.85 0.33 0.10], 'DisplayName', 'fit');
            app.UI.PlotFun  = plot(ax, NaN, NaN, '--', 'LineWidth', 1.4, ...
                'Color', [0.47 0.67 0.19], 'DisplayName', 'function');
        end

        %------------------------------------------------------------------
        function buildSeriesTab(app, tab)
            g = uigridlayout(tab, [5 1]);
            g.RowHeight = {'fit', '1x', 'fit', '1x', 'fit'};
            g.ColumnWidth = {'1x'};
            g.Padding = [8 8 8 8]; g.RowSpacing = 6;

            l = uilabel(g, 'Text', 'Series', 'FontWeight', 'bold');
            l.Layout.Row = 1; l.Layout.Column = 1;

            lb = uilistbox(g, 'Items', {'(empty)'}, 'ItemsData', 1, ...
                'ValueChangedFcn', @(s,~) app.selectSeries(s.Value));
            lb.Layout.Row = 2; lb.Layout.Column = 1;
            app.UI.SeriesList = lb;

            l = uilabel(g, 'Text', 'Frames', 'FontWeight', 'bold');
            l.Layout.Row = 3; l.Layout.Column = 1;
            app.UI.FrameListLabel = l;

            fl = uilistbox(g, 'Items', {'(empty)'}, 'ItemsData', 1, ...
                'ValueChangedFcn', @(s,~) app.gotoFrame(s.Value));
            fl.Layout.Row = 4; fl.Layout.Column = 1;
            app.UI.FrameList = fl;

            l = uilabel(g, 'Text', '', 'WordWrap', 'on', 'VerticalAlignment', 'top');
            l.Layout.Row = 5; l.Layout.Column = 1;
            app.UI.SeriesInfo = l;
        end

        %------------------------------------------------------------------
        function buildROITab(app, tab)
            g = uigridlayout(tab, [8 2]);
            g.RowHeight = {'fit','fit','fit','1x','fit','fit','fit','fit'};
            g.ColumnWidth = {'1x','1x'};
            g.Padding = [8 8 8 8]; g.RowSpacing = 5;

            l = uilabel(g, 'Text', 'Draw a new region', 'FontWeight', 'bold');
            l.Layout.Row = 1; l.Layout.Column = [1 2];

            dd = uidropdown(g, 'Items', {'Polygon','Freehand','Ellipse','Rectangle','Circle','Point'});
            dd.Layout.Row = 2; dd.Layout.Column = 1;
            app.UI.ROIShape = dd;
            b = uibutton(g, 'push', 'Text', 'New ROI', ...
                'ButtonPushedFcn', @(~,~) app.newROI(string(app.UI.ROIShape.Value)));
            b.Layout.Row = 2; b.Layout.Column = 2;
            app.UI.BtnNewROI = b;

            b = uibutton(g, 'push', 'Text', 'Auto ROI by threshold...', ...
                'ButtonPushedFcn', @(~,~) app.uiAutoROI());
            b.Layout.Row = 3; b.Layout.Column = [1 2];

            t = uitable(g);
            t.Layout.Row = 4; t.Layout.Column = [1 2];
            t.ColumnName = {'Show','Name','N','Mean','SD'};
            t.ColumnEditable = [true true false false false];
            t.ColumnWidth = {45, 'auto', 45, 70, 70};
            t.SelectionType = 'row';
            t.Multiselect = 'on';
            t.CellEditCallback = @(s,e) app.onROITableEdit(e);
            t.SelectionChangedFcn = @(s,e) app.onROITableSelect(e);
            app.UI.ROITable = t;

            b = uibutton(g, 'push', 'Text', 'Delete selected', ...
                'ButtonPushedFcn', @(~,~) app.deleteSelectedROIs());
            b.Layout.Row = 5; b.Layout.Column = 1;
            b = uibutton(g, 'push', 'Text', 'Delete all (frame)', ...
                'ButtonPushedFcn', @(~,~) app.deleteFrameROIs());
            b.Layout.Row = 5; b.Layout.Column = 2;

            b = uibutton(g, 'push', 'Text', 'Copy selected to frames...', ...
                'ButtonPushedFcn', @(~,~) app.uiCopyROIToFrames());
            b.Layout.Row = 6; b.Layout.Column = [1 2];

            c = uicheckbox(g, 'Text', 'Show ROIs from all frames (sticky)', ...
                'ValueChangedFcn', @(s,~) app.setShowAllROIs(s.Value));
            c.Layout.Row = 7; c.Layout.Column = [1 2];
            app.UI.ChkSticky = c;

            l = uilabel(g, 'Text', '', 'WordWrap', 'on', 'VerticalAlignment', 'top');
            l.Layout.Row = 8; l.Layout.Column = [1 2];
            app.UI.ROISummary = l;

            if ~app.HasIPT
                app.UI.BtnNewROI.Enable = 'off';
                app.UI.ROIShape.Enable = 'off';
                app.UI.ROISummary.Text = ['Image Processing Toolbox not found: ' ...
                    'interactive drawing is disabled. Threshold ROIs and imported ' ...
                    'masks still work.'];
            end
        end

        %------------------------------------------------------------------
        function buildDisplayTab(app, tab)
            g = uigridlayout(tab, [15 2]);
            g.RowHeight = repmat({'fit'}, 1, 15);
            g.RowHeight{15} = '1x';
            g.ColumnWidth = {130,'1x'};
            g.Padding = [8 8 8 8]; g.RowSpacing = 5;

            lab = @(r, txt) app.gridLabel(g, r, 1, txt);
            head = @(r, txt) app.gridHeader(g, r, txt);

            head(1, 'Colour mapping');

            lab(2, 'Colormap');
            dd = uidropdown(g, 'Items', cellstr(ImageBrowserApp.colormapNames()), ...
                'Value', 'gray', 'ValueChangedFcn', @(s,~) app.setColormap(string(s.Value)));
            dd.Layout.Row = 2; dd.Layout.Column = 2;
            app.UI.CmapDrop = dd;

            c = uicheckbox(g, 'Text', 'Invert colormap', ...
                'ValueChangedFcn', @(s,~) app.setInvert(s.Value));
            c.Layout.Row = 3; c.Layout.Column = 1;
            app.UI.ChkInvert = c;
            c = uicheckbox(g, 'Text', 'Colorbar', ...
                'ValueChangedFcn', @(s,~) app.setColorbar(s.Value));
            c.Layout.Row = 3; c.Layout.Column = 2;
            app.UI.ChkColorbar = c;

            lab(4, 'Limits mode');
            dd = uidropdown(g, 'Items', {'Min-max','Robust %','Manual'}, ...
                'ItemsData', {'minmax','robust','manual'}, ...
                'ValueChangedFcn', @(s,~) app.setCLimMode(string(s.Value)));
            dd.Layout.Row = 4; dd.Layout.Column = 2;
            app.UI.CLimModeDrop = dd;

            lab(5, 'Clip each end (%)');
            sp = uispinner(g, 'Limits', [0 25], 'Value', 1, 'Step', 0.5, ...
                'ValueChangedFcn', @(s,~) app.setRobustPct(s.Value));
            sp.Layout.Row = 5; sp.Layout.Column = 2;
            app.UI.RobustSpin = sp;

            lab(6, 'Lower limit');
            e = uieditfield(g, 'numeric', 'ValueChangedFcn', @(~,~) app.onCLimEdit());
            e.Layout.Row = 6; e.Layout.Column = 2;
            app.UI.CLimLo = e;

            lab(7, 'Upper limit');
            e = uieditfield(g, 'numeric', 'ValueChangedFcn', @(~,~) app.onCLimEdit());
            e.Layout.Row = 7; e.Layout.Column = 2;
            app.UI.CLimHi = e;

            c = uicheckbox(g, 'Text', 'Lock limits when changing frame', ...
                'ValueChangedFcn', @(s,~) app.setCLimLock(s.Value));
            c.Layout.Row = 8; c.Layout.Column = [1 2];
            app.UI.ChkLock = c;

            wl = uigridlayout(g, [1 4]);
            wl.Layout.Row = 9; wl.Layout.Column = [1 2];
            wl.ColumnWidth = {'1x','1x','1x','1x'};
            wl.RowHeight = {26}; wl.Padding = [0 0 0 0]; wl.ColumnSpacing = 3;
            uibutton(wl, 'push', 'Text', 'Bright +', 'Tooltip', 'Lower the colour limits', ...
                'ButtonPushedFcn', @(~,~) app.adjustWL(10, 0));
            uibutton(wl, 'push', 'Text', 'Bright -', 'Tooltip', 'Raise the colour limits', ...
                'ButtonPushedFcn', @(~,~) app.adjustWL(-10, 0));
            uibutton(wl, 'push', 'Text', 'Contr +', 'Tooltip', 'Narrow the colour limits', ...
                'ButtonPushedFcn', @(~,~) app.adjustWL(0, 10));
            uibutton(wl, 'push', 'Text', 'Contr -', 'Tooltip', 'Widen the colour limits', ...
                'ButtonPushedFcn', @(~,~) app.adjustWL(0, -10));

            head(10, 'Overlay');

            c = uicheckbox(g, 'Text', 'Show overlay', ...
                'ValueChangedFcn', @(s,~) app.setOverlayEnabled(s.Value));
            c.Layout.Row = 11; c.Layout.Column = 1;
            app.UI.ChkOverlay = c;
            b = uibutton(g, 'push', 'Text', 'Load from workspace...', ...
                'ButtonPushedFcn', @(~,~) app.uiLoadOverlay());
            b.Layout.Row = 11; b.Layout.Column = 2;

            lab(12, 'Overlay colormap');
            dd = uidropdown(g, 'Items', cellstr(ImageBrowserApp.colormapNames()), ...
                'Value', 'hot', 'ValueChangedFcn', @(s,~) app.setOverlayCmap(string(s.Value)));
            dd.Layout.Row = 12; dd.Layout.Column = 2;
            app.UI.OvCmap = dd;

            lab(13, 'Opacity');
            sl = uislider(g, 'Limits', [0 1], 'Value', 0.5, 'MajorTicks', [0 0.5 1], ...
                'MinorTicks', [], 'ValueChangingFcn', @(~,e) app.setOverlayAlpha(e.Value), ...
                'ValueChangedFcn', @(s,~) app.setOverlayAlpha(s.Value));
            sl.Layout.Row = 13; sl.Layout.Column = 2;
            app.UI.OvAlpha = sl;

            lab(14, 'Hide overlay below');
            e = uieditfield(g, 'numeric', 'Value', 0, ...
                'ValueChangedFcn', @(s,~) app.setOverlayThreshold(s.Value));
            e.Layout.Row = 14; e.Layout.Column = 2;
            app.UI.OvThresh = e;

            gg = uigridlayout(g, [1 2]);
            gg.Layout.Row = 15; gg.Layout.Column = [1 2];
            gg.ColumnWidth = {130,'1x'};
            gg.RowHeight = {26}; gg.Padding = [0 0 0 0];
            l = uilabel(gg, 'Text', 'Window/level acts on');
            l.Layout.Row = 1; l.Layout.Column = 1;
            dd = uidropdown(gg, 'Items', {'Base','Overlay'}, ...
                'ItemsData', {'base','overlay'}, ...
                'ValueChangedFcn', @(s,~) app.setActiveLayer(string(s.Value)));
            dd.Layout.Row = 1; dd.Layout.Column = 2;
            app.UI.LayerDrop = dd;
        end

        %------------------------------------------------------------------
        function buildAnalysisTab(app, tab)
            g = uigridlayout(tab, [21 2]);
            g.RowHeight = repmat({'fit'}, 1, 21);
            g.RowHeight{21} = '1x';
            g.ColumnWidth = {130,'1x'};
            g.Padding = [8 8 8 8]; g.RowSpacing = 5;

            lab = @(r, txt) app.gridLabel(g, r, 1, txt);
            head = @(r, txt) app.gridHeader(g, r, txt);

            head(1, 'Signal plot');

            lab(2, 'Plot');
            dd = uidropdown(g, 'Items', {'Pixel under cursor','ROI mean'}, ...
                'ItemsData', {'pixel','roi'}, ...
                'ValueChangedFcn', @(s,~) app.setPlotMode(string(s.Value)));
            dd.Layout.Row = 2; dd.Layout.Column = 2;
            app.UI.PlotModeDrop = dd;

            lab(3, 'Sweep over');
            dd = uidropdown(g, 'Items', {'(none)'}, 'ItemsData', 0, ...
                'ValueChangedFcn', @(s,~) app.setSweepDim(s.Value));
            dd.Layout.Row = 3; dd.Layout.Column = 2;
            app.UI.SweepDrop = dd;

            lab(4, 'From');
            sp = uispinner(g, 'Limits', [1 Inf], 'Value', 1, 'Step', 1, ...
                'RoundFractionalValues', 'on', 'ValueDisplayFormat', '%d', ...
                'ValueChangedFcn', @(~,~) app.onRangeEdit());
            sp.Layout.Row = 4; sp.Layout.Column = 2;
            app.UI.FromSpin = sp;

            lab(5, 'To');
            sp = uispinner(g, 'Limits', [1 Inf], 'Value', 1, 'Step', 1, ...
                'RoundFractionalValues', 'on', 'ValueDisplayFormat', '%d', ...
                'ValueChangedFcn', @(~,~) app.onRangeEdit());
            sp.Layout.Row = 5; sp.Layout.Column = 2;
            app.UI.ToSpin = sp;

            c = uicheckbox(g, 'Text', 'Pixel surfing (live update)', ...
                'ValueChangedFcn', @(s,~) app.setPixelSurf(s.Value));
            c.Layout.Row = 6; c.Layout.Column = [1 2];
            app.UI.ChkPixelSurf = c;

            c = uicheckbox(g, 'Text', 'Log y', 'ValueChangedFcn', @(~,~) app.updatePlotScales());
            c.Layout.Row = 7; c.Layout.Column = 1;
            app.UI.ChkLogY = c;
            c = uicheckbox(g, 'Text', 'Log x', 'ValueChangedFcn', @(~,~) app.updatePlotScales());
            c.Layout.Row = 7; c.Layout.Column = 2;
            app.UI.ChkLogX = c;

            c = uicheckbox(g, 'Text', 'Shade +/- SD for ROI curves', 'Value', true, ...
                'ValueChangedFcn', @(~,~) app.refreshPlot());
            c.Layout.Row = 8; c.Layout.Column = [1 2];
            app.UI.ChkSD = c;

            head(9, 'X axis');

            b = uibutton(g, 'push', 'Text', 'Set from workspace...', ...
                'ButtonPushedFcn', @(~,~) app.uiSetXData());
            b.Layout.Row = 10; b.Layout.Column = 1;
            b = uibutton(g, 'push', 'Text', 'Clear', ...
                'ButtonPushedFcn', @(~,~) app.clearXData());
            b.Layout.Row = 10; b.Layout.Column = 2;

            lab(11, 'Label');
            e = uieditfield(g, 'text', 'Value', 'Frame', ...
                'ValueChangedFcn', @(s,~) app.setXLabel(string(s.Value)));
            e.Layout.Row = 11; e.Layout.Column = 2;
            app.UI.XLabelEdit = e;

            head(12, 'Diffusion fit');

            lab(13, 'Fit region');
            dd = uidropdown(g, 'Items', {'(no region shown)'}, ...
                'Tooltip', ['Which region the fit describes. Independent of the ' ...
                'table selection, which only drives Delete and Copy.']);
            dd.Layout.Row = 13; dd.Layout.Column = 2;
            app.UI.FitROIDrop = dd;

            lab(14, 'Model');
            dd = uidropdown(g, 'Items', {'DTI  S0 exp(-bD)', 'DKI  + b^2D^2K/6'}, ...
                'ItemsData', {'DTI', 'DKI'}, 'Value', 'DKI', ...
                'Tooltip', ['DTI is the special case K = 0. The x-axis must hold ' ...
                'b-values for the parameters to mean anything.']);
            dd.Layout.Row = 14; dd.Layout.Column = 2;
            app.UI.FitModelDrop = dd;

            c = uicheckbox(g, 'Text', 'Weight log stage by S^2', 'Value', true, ...
                'Tooltip', ['Taking logs makes the noise heteroscedastic; weights ' ...
                'proportional to S^2 undo that to first order.']);
            c.Layout.Row = 15; c.Layout.Column = [1 2];
            app.UI.FitWeighted = c;

            c = uicheckbox(g, 'Text', 'Refine by nonlinear least squares', 'Value', true, ...
                'Tooltip', ['lsqcurvefit with an analytic Jacobian, started from the ' ...
                'log-linear estimate.']);
            c.Layout.Row = 16; c.Layout.Column = [1 2];
            app.UI.FitRefine = c;

            b = uibutton(g, 'push', 'Text', 'Fit current curve', ...
                'ButtonPushedFcn', @(~,~) app.uiFitDiffusion());
            b.Layout.Row = 17; b.Layout.Column = 1;
            b = uibutton(g, 'push', 'Text', 'Clear fit', ...
                'ButtonPushedFcn', @(~,~) app.clearFit());
            b.Layout.Row = 17; b.Layout.Column = 2;

            l = uilabel(g, 'Text', 'No fit yet.', 'WordWrap', 'on', ...
                'VerticalAlignment', 'top', 'FontName', 'Consolas');
            l.Layout.Row = 18; l.Layout.Column = [1 2];
            app.UI.FitInfo = l;

            head(19, 'Other');

            b = uibutton(g, 'push', 'Text', 'Plot a function...', ...
                'ButtonPushedFcn', @(~,~) app.uiPlotFunction());
            b.Layout.Row = 20; b.Layout.Column = 1;
            b = uibutton(g, 'push', 'Text', 'Export plot data...', ...
                'ButtonPushedFcn', @(~,~) app.uiExportPlotData());
            b.Layout.Row = 20; b.Layout.Column = 2;

            l = uilabel(g, 'Text', '', 'WordWrap', 'on', 'VerticalAlignment', 'top');
            l.Layout.Row = 21; l.Layout.Column = [1 2];
            app.UI.PlotInfo = l;
        end

        function h = gridLabel(~, g, r, c, txt)
            h = uilabel(g, 'Text', txt, 'HorizontalAlignment', 'left');
            h.Layout.Row = r; h.Layout.Column = c;
        end

        function h = gridHeader(~, g, r, txt)
            h = uilabel(g, 'Text', txt, 'FontWeight', 'bold');
            h.Layout.Row = r; h.Layout.Column = [1 2];
        end
    end

    %======================================================================
    % Data model
    %======================================================================
    methods (Static, Access = private)

        function s = emptySeries()
            s = struct('Name', {}, 'Data', {}, 'IsRGB', {}, ...
                'NavDims', {}, 'NavSize', {}, 'DimNames', {});
            s = reshape(s, 1, 0);
        end

        function r = emptyROI()
            r = struct('Series', {}, 'Frame', {}, 'Name', {}, 'Shape', {}, ...
                'Pos', {}, 'Mask', {}, 'Color', {}, 'Visible', {});
            r = reshape(r, 1, 0);
        end

        function S = buildSeries(data, prefix, isRGB)
            %BUILDSERIES  Recursively turn user input into a series struct array.
            if nargin < 2, prefix = string.empty; end
            if nargin < 3, isRGB = []; end
            prefix = string(prefix);
            S = ImageBrowserApp.emptySeries();

            if isnumeric(data) || islogical(data)
                if isempty(data), return; end
                if isscalar(prefix) && strlength(prefix) > 0
                    nm = prefix;
                else
                    nm = "image";
                end
                S = ImageBrowserApp.oneSeries(data, nm, isRGB);

            elseif iscell(data)
                for i = 1:numel(data)
                    if numel(prefix) == numel(data)
                        p = prefix(i);
                    elseif isscalar(prefix) && strlength(prefix) > 0
                        p = prefix + "{" + i + "}";
                    else
                        p = "series " + i;
                    end
                    S = [S, ImageBrowserApp.buildSeries(data{i}, p, isRGB)]; %#ok<AGROW>
                end

            elseif isstruct(data) && isscalar(data)
                f = string(fieldnames(data));
                for i = 1:numel(f)
                    if isscalar(prefix) && strlength(prefix) > 0
                        p = prefix + "." + f(i);
                    else
                        p = f(i);
                    end
                    S = [S, ImageBrowserApp.buildSeries(data.(f(i)), p, isRGB)]; %#ok<AGROW>
                end

            elseif isstruct(data)
                for k = 1:numel(data)
                    if isscalar(prefix) && strlength(prefix) > 0
                        p = prefix + "(" + k + ")";
                    else
                        p = "(" + k + ")";
                    end
                    S = [S, ImageBrowserApp.buildSeries(data(k), p, isRGB)]; %#ok<AGROW>
                end
            end
        end

        function s = oneSeries(data, name, isRGB)
            sz = size(data);
            if numel(sz) < 2, sz = [sz 1]; end
            if isempty(isRGB)
                rgb = numel(sz) >= 3 && sz(3) == 3 && isa(data, 'uint8');
            else
                rgb = logical(isRGB) && numel(sz) >= 3 && sz(3) == 3;
            end
            first   = 3 + double(rgb);
            navDims = first:numel(sz);
            navSize = sz(navDims);
            dimNames = "dim " + string(navDims);
            if numel(navDims) >= 1, dimNames(1) = "slice";  end
            if numel(navDims) >= 2, dimNames(2) = "volume"; end
            s = struct('Name', string(name), 'Data', {data}, 'IsRGB', rgb, ...
                'NavDims', navDims, 'NavSize', navSize, 'DimNames', dimNames);
        end

        function nm = colormapNames()
            cand = ["gray" "bone" "pink" "copper" "parula" "turbo" "sky" "abyss" ...
                "jet" "hot" "hsv" "cool" "spring" "summer" "autumn" "winter" ...
                "lines" "colorcube" "prism" "flag" "white"];
            keep = false(size(cand));
            for k = 1:numel(cand)
                keep(k) = ~isempty(which(cand(k)));
            end
            nm = cand(keep);
            if isempty(nm), nm = "gray"; end
        end

        function img = splashImage()
            n = 256;
            [X, Y] = meshgrid(linspace(-1, 1, n));
            R = hypot(X, Y);
            A = 0.5 + 0.5 * sin(14 * R - 2.2);
            B = 0.5 + 0.5 * sin(14 * R - 0.8);
            C = 0.5 + 0.5 * sin(14 * R + 0.6);
            V = exp(-2.2 * R.^2);
            img = uint8(255 * cat(3, A .* V, B .* V, C .* V));
        end

        function lim = safeLimits(x)
            x = x(isfinite(x));
            if isempty(x)
                lim = [0 1];
                return
            end
            lo = double(min(x(:)));
            hi = double(max(x(:)));
            lim = ImageBrowserApp.widen([lo hi]);
        end

        function lim = robustLimits(x, pct)
            x = double(x(isfinite(x)));
            if isempty(x)
                lim = [0 1];
                return
            end
            x = sort(x(:));
            n = numel(x);
            k = max(1, min(n, round(n * pct / 100)));
            lim = ImageBrowserApp.widen([x(k) x(n - k + 1)]);
        end

        function lim = widen(lim)
            if ~isfinite(lim(1)) || ~isfinite(lim(2)), lim = [0 1]; return; end
            if lim(2) <= lim(1)
                d = max(abs(lim(1)), 1) * 1e-3;
                lim = [lim(1) - d, lim(1) + d];
            end
        end

        function s = maskStats(img, mask)
            s = struct('N', 0, 'Mean', NaN, 'SD', NaN, 'Min', NaN, 'Max', NaN, 'Median', NaN);
            if isempty(mask) || ~any(mask(:)), return; end
            if size(img,1) ~= size(mask,1) || size(img,2) ~= size(mask,2), return; end
            if size(img,3) > 1
                img = mean(double(img), 3);
            end
            v = double(img(mask));
            v = v(isfinite(v));
            s.N = numel(v);
            if s.N == 0, return; end
            s.Mean   = mean(v);
            s.SD     = std(v);
            s.Min    = min(v);
            s.Max    = max(v);
            s.Median = median(v);
        end

        function [X, Y] = maskOutline(mask)
            %MASKOUTLINE  Pixel-edge outline of a logical mask.
            %   Returns coordinate vectors with NaN separators so the whole
            %   boundary can be drawn with a single line object.
            [R, C] = size(mask);
            M = false(R + 2, C + 2);
            M(2:end-1, 2:end-1) = logical(mask);

            vd = M(2:R+1, 1:C+1) ~= M(2:R+1, 2:C+2);   % vertical edges
            [i, k] = find(vd);
            Xv = [k - 0.5, k - 0.5, nan(size(k))]';
            Yv = [i - 0.5, i + 0.5, nan(size(i))]';

            hd = M(1:R+1, 2:C+1) ~= M(2:R+2, 2:C+1);   % horizontal edges
            [k2, j] = find(hd);
            Xh = [j - 0.5, j + 0.5, nan(size(j))]';
            Yh = [k2 - 0.5, k2 - 0.5, nan(size(k2))]';

            X = [Xv(:); Xh(:)];
            Y = [Yv(:); Yh(:)];
        end

        function v = sub2linear(sz, sub)
            if isempty(sz), v = 1; return; end
            c = num2cell(sub);
            if isscalar(sz)
                v = sub(1);
            else
                v = sub2ind(sz, c{:});
            end
        end

        function sub = linear2sub(sz, v)
            if isempty(sz), sub = zeros(1,0); return; end
            if isscalar(sz)
                sub = v;
            else
                c = cell(1, numel(sz));
                [c{:}] = ind2sub(sz, v);
                sub = cell2mat(c);
            end
        end
    end

    %======================================================================
    % Series / frame navigation
    %======================================================================
    methods (Access = private)

        function n = seriesCount(app)
            n = numel(app.Series);
        end

        function n = frameCount(app, si)
            if nargin < 2, si = app.SeriesIndex; end
            if app.seriesCount() == 0, n = 0; return; end
            ns = app.Series(si).NavSize;
            if isempty(ns), n = 1; else, n = prod(ns); end
        end

        function v = frameLinear(app)
            if app.seriesCount() == 0, v = 1; return; end
            v = ImageBrowserApp.sub2linear(app.Series(app.SeriesIndex).NavSize, app.Sub);
        end

        function selectSeries(app, si)
            if app.seriesCount() == 0, return; end
            si = max(1, min(app.seriesCount(), round(si)));
            app.SeriesIndex = si;
            ns = app.Series(si).NavSize;
            app.Sub = ones(1, numel(ns));
            app.clearLiveROIs();
            app.configureNav();
            app.configureSweep();
            app.refreshFrameList();
            if ~app.CLimLock
                app.autoCLim();
            end
            if any(app.UI.SeriesList.ItemsData == si)
                app.UI.SeriesList.Value = si;
            end
            app.resetView();
            app.refreshAll();
        end

        function gotoFrame(app, f)
            if app.seriesCount() == 0, return; end
            n = app.frameCount();
            f = max(1, min(n, round(f)));
            app.Sub = ImageBrowserApp.linear2sub(app.Series(app.SeriesIndex).NavSize, f);
            app.clearLiveROIs();
            if ~app.CLimLock, app.autoCLim(); end
            app.refreshAll();
        end

        function stepFrame(app, d)
            if app.seriesCount() == 0, return; end
            k = app.cineDim();
            ns = app.Series(app.SeriesIndex).NavSize;
            if isempty(ns), return; end
            v = app.Sub(k) + d;
            v = mod(v - 1, ns(k)) + 1;      % wrap around
            app.setNavDim(k, v);
        end

        function setNavDim(app, k, v)
            ns = app.Series(app.SeriesIndex).NavSize;
            if isempty(ns) || k > numel(ns), return; end
            v = max(1, min(ns(k), round(v)));
            if v == app.Sub(k), return; end
            app.Sub(k) = v;
            app.clearLiveROIs();
            if ~app.CLimLock, app.autoCLim(); end
            app.refreshAll();
        end

        function k = cineDim(app)
            k = 1;
            if app.seriesCount() == 0, return; end
            if isfield(app.UI, 'CineDim') && isvalid(app.UI.CineDim) && ...
                    ~isempty(app.UI.CineDim.Value)
                k = app.UI.CineDim.Value;
            end
            ns = app.Series(app.SeriesIndex).NavSize;
            k = max(1, min(max(1, numel(ns)), k));
        end

        function img = currentImage(app)
            img = app.imageAt(app.SeriesIndex, app.frameLinear());
        end

        function img = imageAt(app, si, frame)
            if app.seriesCount() == 0 || si < 1 || si > app.seriesCount()
                img = zeros(2, 2);
                return
            end
            s = app.Series(si);
            sub = ImageBrowserApp.linear2sub(s.NavSize, ...
                max(1, min(max(1, prod([s.NavSize 1])), frame)));
            idx = repmat({':'}, 1, max(2, ndims(s.Data)));
            for d = 1:numel(sub)
                idx{s.NavDims(d)} = sub(d);
            end
            img = s.Data(idx{:});
            r = size(s.Data, 1); c = size(s.Data, 2);
            if s.IsRGB
                img = reshape(img, [r c 3]);
            else
                img = reshape(img, [r c]);
            end
        end

        function img = imageAtSub(app, si, sub)
            s = app.Series(si);
            idx = repmat({':'}, 1, max(2, ndims(s.Data)));
            for d = 1:numel(sub)
                idx{s.NavDims(d)} = sub(d);
            end
            img = s.Data(idx{:});
            r = size(s.Data, 1); c = size(s.Data, 2);
            if s.IsRGB
                img = reshape(img, [r c 3]);
            else
                img = reshape(img, [r c]);
            end
        end
    end

    %======================================================================
    % Display
    %======================================================================
    methods (Access = private)

        function refreshAll(app)
            if app.Closing, return; end
            app.refreshImage();
            app.refreshROIDisplay();
            app.refreshNavControls();
            app.refreshROITable();
            app.refreshStatus();
            app.refreshPlot();
        end

        function refreshImage(app)
            if app.seriesCount() == 0, return; end
            ax = app.UI.Axes;

            if app.MontageOn
                [cd, app.MontageMap] = app.buildMontage();
            else
                cd = app.currentImage();
                app.MontageMap = [];
            end

            s = app.Series(app.SeriesIndex);
            lim = app.CLimStore;
            if s.IsRGB
                % Truecolor: apply window/level by rescaling before display,
                % so the brightness/contrast controls work for RGB too.
                d = (double(cd) - lim(1)) / max(eps, lim(2) - lim(1));
                cdata = min(1, max(0, d));
                cdata(~isfinite(cdata)) = 0;
                alpha = 1;
            else
                cdata = double(cd);
                if all(isfinite(cdata(:)))
                    alpha = 1;
                else
                    alpha = double(isfinite(cdata));
                end
                ax.CLim = lim;
            end

            app.UI.Image.CData = cdata;
            app.UI.Image.XData = [1 size(cdata, 2)];
            app.UI.Image.YData = [1 size(cdata, 1)];
            app.UI.Image.AlphaData = alpha;

            if ~isequal(app.UI.Image.UserData, size(cdata, [1 2]))
                app.UI.Image.UserData = size(cdata, [1 2]);
                app.resetView();
            end

            app.refreshOverlay(size(cdata, 1), size(cdata, 2));
            app.applyColormap();
        end

        function refreshOverlay(app, nr, nc)
            ov = app.UI.OverlayImage;
            if ~app.Overlay.Enabled || isempty(app.Overlay.Data) || app.MontageOn
                ov.Visible = 'off';
                return
            end
            slice = app.overlaySlice();
            if isempty(slice) || size(slice,1) ~= nr || size(slice,2) ~= nc
                ov.Visible = 'off';
                return
            end
            lim = app.Overlay.CLim;
            cmap = ImageBrowserApp.resolveColormap(app.Overlay.Colormap, 256);
            idx = round((slice - lim(1)) / max(eps, lim(2) - lim(1)) * (size(cmap,1) - 1)) + 1;
            idx = min(size(cmap,1), max(1, idx));
            idx(~isfinite(slice)) = 1;
            rgb = ind2rgb(idx, cmap);
            a = app.Overlay.Alpha * double(isfinite(slice) & slice >= app.Overlay.Threshold);
            ov.CData = rgb;
            ov.AlphaData = a;
            ov.XData = [1 nc];
            ov.YData = [1 nr];
            ov.Visible = 'on';
            uistack(ov, 'top');
        end

        function slice = overlaySlice(app)
            D = app.Overlay.Data;
            s = app.Series(app.SeriesIndex);
            slice = [];
            if isempty(D), return; end
            if ismatrix(D)
                slice = D;
                return
            end
            if isequal(size(D), size(s.Data)) && ~s.IsRGB
                idx = repmat({':'}, 1, max(2, ndims(D)));
                for d = 1:numel(app.Sub)
                    idx{s.NavDims(d)} = app.Sub(d);
                end
                slice = reshape(D(idx{:}), size(D,1), size(D,2));
            else
                f = min(size(D, 3), app.frameLinear());
                slice = D(:,:,f);
            end
        end

        function [cd, map] = buildMontage(app)
            n = app.frameCount();
            maxTiles = 400;
            if n > maxTiles
                map = round(linspace(1, n, maxTiles));
            else
                map = 1:n;
            end
            k = numel(map);
            cols = ceil(sqrt(k));
            rows = ceil(k / cols);
            im1 = app.imageAt(app.SeriesIndex, map(1));
            [r, c, p] = size(im1);
            cd = nan(rows * r, cols * c, p);
            for t = 1:k
                ri = floor((t - 1) / cols);
                ci = mod(t - 1, cols);
                cd(ri*r + (1:r), ci*c + (1:c), :) = double(app.imageAt(app.SeriesIndex, map(t)));
            end
            app.UI.Image.UserData = [];  % force a view reset
            map = struct('Frames', map, 'Rows', rows, 'Cols', cols, 'H', r, 'W', c);
        end

        function applyColormap(app)
            cmap = ImageBrowserApp.resolveColormap(app.CmapName, 256);
            if app.CmapInvert, cmap = flipud(cmap); end
            colormap(app.UI.Axes, cmap);
        end

        function resetView(app)
            if ~isfield(app.UI, 'Image') || ~isvalid(app.UI.Image), return; end
            sz = size(app.UI.Image.CData);
            if numel(sz) < 2 || any(sz(1:2) == 0), return; end
            app.UI.Axes.XLim = [0.5, sz(2) + 0.5];
            app.UI.Axes.YLim = [0.5, sz(1) + 0.5];
        end

        %------------------------------------------------------------------
        % Colour limits
        %------------------------------------------------------------------
        function autoCLim(app)
            if app.seriesCount() == 0, return; end
            if app.CLimMode == "manual", return; end
            img = app.currentImage();
            if app.CLimMode == "robust"
                app.setCLim(ImageBrowserApp.robustLimits(img, app.RobustPct));
            else
                app.setCLim(ImageBrowserApp.safeLimits(img));
            end
        end

        function setCLim(app, lim)
            lim = ImageBrowserApp.widen(double(lim(:)'));
            if app.ActiveLayer == "overlay" && app.Overlay.Enabled
                app.Overlay.CLim = lim;
            else
                app.CLimStore = lim;
            end
            app.syncCLimControls();
            app.refreshImage();
            app.refreshStatus();
        end

        function lim = activeCLim(app)
            if app.ActiveLayer == "overlay" && app.Overlay.Enabled
                lim = app.Overlay.CLim;
            else
                lim = app.CLimStore;
            end
        end

        function resetCLim(app)
            app.CLimMode = "minmax";
            app.UI.CLimModeDrop.Value = 'minmax';
            if app.ActiveLayer == "overlay" && app.Overlay.Enabled
                app.setCLim(ImageBrowserApp.safeLimits(app.Overlay.Data));
            else
                app.setCLim(ImageBrowserApp.safeLimits(app.currentImage()));
            end
        end

        function setCLimMode(app, mode)
            app.CLimMode = mode;
            app.UI.CLimModeDrop.Value = char(mode);
            if mode ~= "manual"
                app.autoCLim();
            end
            app.syncCLimControls();
        end

        function setRobustPct(app, p)
            app.RobustPct = p;
            if app.CLimMode == "robust", app.autoCLim(); end
        end

        function adjustWL(app, brightness, contrast)
            lim = app.activeCLim();
            w = lim(2) - lim(1);
            lim = lim - brightness / 100 * w;
            lim = lim + [1 -1] * contrast / 200 * w;
            app.CLimMode = "manual";
            app.UI.CLimModeDrop.Value = 'manual';
            app.setCLim(lim);
        end

        function setCLimLock(app, tf)
            app.CLimLock = logical(tf);
            app.UI.ChkLock.Value = app.CLimLock;
            app.UI.BtnLock.Value = app.CLimLock;
        end

        function toggleCLimLock(app)
            app.setCLimLock(~app.CLimLock);
        end

        function onCLimEdit(app)
            app.CLimMode = "manual";
            app.UI.CLimModeDrop.Value = 'manual';
            app.setCLim([app.UI.CLimLo.Value, app.UI.CLimHi.Value]);
        end

        function syncCLimControls(app)
            lim = app.activeCLim();
            app.UI.CLimLo.Value = lim(1);
            app.UI.CLimHi.Value = lim(2);
        end

        %------------------------------------------------------------------
        % Colormap / colorbar
        %------------------------------------------------------------------
        function setColormap(app, name)
            app.CmapName = string(name);
            if any(strcmp(app.UI.CmapDrop.Items, char(name)))
                app.UI.CmapDrop.Value = char(name);
            end
            app.applyColormap();
        end

        function setInvert(app, tf)
            app.CmapInvert = logical(tf);
            app.UI.ChkInvert.Value = app.CmapInvert;
            if isgraphics(app.UI.MenuInvert)
                app.UI.MenuInvert.Checked = matlab.lang.OnOffSwitchState(app.CmapInvert);
            end
            app.applyColormap();
        end

        function toggleInvert(app)
            app.setInvert(~app.CmapInvert);
        end

        function setColorbar(app, tf)
            tf = logical(tf);
            app.UI.CBar.Visible = matlab.lang.OnOffSwitchState(tf);
            app.UI.ChkColorbar.Value = tf;
            app.UI.BtnColorbar.Value = tf;
            app.UI.MenuColorbar.Checked = matlab.lang.OnOffSwitchState(tf);
        end

        function toggleColorbar(app)
            app.setColorbar(~logical(app.UI.BtnColorbar.Value));
        end

        %------------------------------------------------------------------
        % Montage / cine
        %------------------------------------------------------------------
        function setMontage(app, tf)
            app.MontageOn = logical(tf);
            app.UI.BtnMontage.Value = app.MontageOn;
            app.UI.MenuMontage.Checked = matlab.lang.OnOffSwitchState(app.MontageOn);
            app.clearLiveROIs();
            app.refreshAll();
            app.resetView();
        end

        function toggleMontage(app)
            app.setMontage(~app.MontageOn);
        end

        function setCine(app, tf)
            if logical(tf)
                app.startCine();
            else
                app.stopCine();
            end
        end

        function startCine(app)
            app.stopCine();
            if app.frameCount() < 2, app.UI.BtnPlay.Value = false; return; end
            p = max(0.02, round(1000 / app.CineFPS) / 1000);
            app.CineTimer = timer('ExecutionMode', 'fixedSpacing', 'Period', p, ...
                'BusyMode', 'drop', 'TimerFcn', @(~,~) app.cineTick());
            start(app.CineTimer);
            app.UI.BtnPlay.Value = true;
            app.UI.BtnPlay.Text = 'Pause';
        end

        function stopCine(app)
            if ~isempty(app.CineTimer) && isvalid(app.CineTimer)
                stop(app.CineTimer);
                delete(app.CineTimer);
            end
            app.CineTimer = [];
            if isfield(app.UI, 'BtnPlay') && isvalid(app.UI.BtnPlay)
                app.UI.BtnPlay.Value = false;
                app.UI.BtnPlay.Text = 'Play';
            end
        end

        function cineTick(app)
            if app.Closing || ~isvalid(app.UI.Fig)
                app.stopCine();
                return
            end
            app.stepFrame(1);
            drawnow limitrate
        end

        function setFPS(app, v)
            app.CineFPS = v;
            if ~isempty(app.CineTimer), app.startCine(); end
        end

        %------------------------------------------------------------------
        % Lists, navigation widgets and status line
        %------------------------------------------------------------------
        function setChoices(~, comp, items, data, value)
            %SETCHOICES  Repopulate a listbox or dropdown safely.
            %   Items and ItemsData must always have the same number of
            %   elements, so ItemsData is cleared before Items is replaced.
            newItems = cellstr(string(items(:))');
            if isequal(comp.Items, newItems) && isequaln(comp.ItemsData, data)
                if nargin >= 5 && ~isempty(value) && ~isempty(data) && ...
                        any(data == value)
                    comp.Value = value;
                end
                return
            end
            comp.ItemsData = [];
            comp.Items = newItems;
            if nargin >= 4 && ~isempty(data)
                comp.ItemsData = data;
                if nargin >= 5 && ~isempty(value) && any(data == value)
                    comp.Value = value;
                end
            end
        end

        function setRangeControl(~, comp, n, value)
            %SETRANGECONTROL  Give a slider or spinner a legal range.
            %   Limits must be strictly increasing, so a single-element
            %   dimension gets the range [1 2] and is disabled instead.
            hi = max(2, n);
            comp.Value = 1;              % always legal, old limits or new
            comp.Limits = [1 hi];
            if nargin >= 4
                comp.Value = min(max(1, value), hi);
            end
            comp.Enable = matlab.lang.OnOffSwitchState(n > 1);
        end

        function refreshSeriesList(app)
            n = app.seriesCount();
            if n == 0
                app.setChoices(app.UI.SeriesList, "(empty)", []);
                return
            end
            items = strings(1, n);
            for k = 1:n
                s = app.Series(k);
                items(k) = sprintf('%d. %s  [%s]', k, s.Name, ...
                    join(string(size(s.Data)), char(215)));
            end
            app.setChoices(app.UI.SeriesList, items, 1:n, min(app.SeriesIndex, n));
        end

        function refreshFrameList(app)
            if app.seriesCount() == 0, return; end
            s = app.Series(app.SeriesIndex);
            n = app.frameCount();
            cap = 2000;
            m = min(n, cap);
            items = strings(1, m);
            for f = 1:m
                sub = ImageBrowserApp.linear2sub(s.NavSize, f);
                if isempty(sub)
                    items(f) = "1. image";
                else
                    parts = s.DimNames(1:numel(sub)) + " " + string(sub);
                    items(f) = sprintf('%d. %s', f, join(parts, ", "));
                end
            end
            if n > cap
                items(end) = items(end) + sprintf('   (+%d more)', n - cap);
            end
            app.setChoices(app.UI.FrameList, items, 1:m, min(app.frameLinear(), m));
            app.UI.FrameListLabel.Text = sprintf('Frames (%d)', n);
        end

        function configureNav(app)
            s = app.Series(app.SeriesIndex);
            ns = s.NavSize;
            nd = numel(ns);
            rh = num2cell(zeros(1, 5));
            for k = 1:4
                if k <= nd
                    rh{k} = 32;
                    app.UI.NavRow(k).Visible = 'on';
                    app.UI.NavLabel(k).Text = char(s.DimNames(k));
                    app.setRangeControl(app.UI.NavSlider(k), ns(k));
                    app.setRangeControl(app.UI.NavSpin(k), ns(k));
                    app.UI.NavMax(k).Text = sprintf('/ %d', ns(k));
                else
                    app.UI.NavRow(k).Visible = 'off';
                end
            end
            rh{5} = 32;
            app.UI.Nav.RowHeight = rh;

            if nd == 0
                app.setChoices(app.UI.CineDim, "(single image)", 1, 1);
                app.UI.CineDim.Enable = 'off';
            else
                app.setChoices(app.UI.CineDim, s.DimNames(1:nd), 1:nd, 1);
                app.UI.CineDim.Enable = 'on';
            end
        end

        function refreshNavControls(app)
            if app.seriesCount() == 0, return; end
            ns = app.Series(app.SeriesIndex).NavSize;
            for k = 1:min(4, numel(ns))
                app.UI.NavSlider(k).Value = app.Sub(k);
                app.UI.NavSpin(k).Value = app.Sub(k);
            end
            f = app.frameLinear();
            if f <= numel(app.UI.FrameList.ItemsData)
                app.UI.FrameList.Value = f;
            end
        end

        function onNavSlider(app, k, v)
            app.setNavDim(k, v);
        end

        function refreshStatus(app)
            if app.seriesCount() == 0, return; end
            s = app.Series(app.SeriesIndex);
            f = app.frameLinear();
            % Build the status line as a string, never as char: "+" on two
            % char vectors is elementwise addition, not concatenation.
            txt = string(sprintf('series %d/%d  %s   frame %d/%d', app.SeriesIndex, ...
                app.seriesCount(), s.Name, f, app.frameCount()));
            if ~isempty(app.Sub)
                parts = s.DimNames(1:numel(app.Sub)) + "=" + string(app.Sub);
                txt = txt + "  (" + join(parts, ", ") + ")";
            end
            p = app.LastPixel;
            if all(isfinite(p))
                img = app.currentImage();
                if p(1) >= 1 && p(2) >= 1 && p(1) <= size(img,1) && p(2) <= size(img,2)
                    if size(img, 3) == 3
                        v = double(squeeze(img(p(1), p(2), :)));
                        txt = txt + sprintf('   i=%d j=%d  RGB=[%.4g %.4g %.4g]', ...
                            p(1), p(2), v(1), v(2), v(3));
                    else
                        txt = txt + sprintf('   i=%d j=%d  value=%.6g', ...
                            p(1), p(2), double(img(p(1), p(2))));
                    end
                end
            end
            lim = app.CLimStore;
            txt = txt + sprintf('   CLim=[%.4g %.4g]', lim(1), lim(2));
            app.UI.Status.Text = char(txt);

            info = sprintf(['%s\nclass %s, size %s\n%d frames, %d navigable ' ...
                'dimension(s)'], s.Name, class(s.Data), ...
                join(string(size(s.Data)), char(215)), app.frameCount(), numel(s.NavSize));
            if s.IsRGB, info = [info newline 'dimension 3 read as RGB colour']; end
            app.UI.SeriesInfo.Text = info;
        end

        %------------------------------------------------------------------
        % Panels and theme
        %------------------------------------------------------------------
        function setPlotPanel(app, tf)
            tf = logical(tf);
            app.UI.PlotPanel.Visible = matlab.lang.OnOffSwitchState(tf);
            rh = app.UI.Left.RowHeight;
            if tf, rh{5} = app.PlotHeight; else, rh{5} = 0; end
            app.UI.Left.RowHeight = rh;
            app.UI.BtnPlotPanel.Value = tf;
            app.UI.MenuPlotPanel.Checked = matlab.lang.OnOffSwitchState(tf);
            if tf, app.refreshPlot(); end
        end

        function togglePlotPanel(app)
            app.setPlotPanel(~logical(app.UI.BtnPlotPanel.Value));
        end

        function setTheme(app, name)
            app.ThemeChoice = string(name);
            app.applyTheme();
        end

        function applyTheme(app)
            for k = 1:numel(app.UI.MenuTheme)
                app.UI.MenuTheme(k).Checked = 'off';
            end
            switch app.ThemeChoice
                case "light", app.UI.MenuTheme(2).Checked = 'on';
                case "dark",  app.UI.MenuTheme(3).Checked = 'on';
                otherwise,    app.UI.MenuTheme(1).Checked = 'on';
            end
            try
                if ~isMATLABReleaseOlderThan("R2025a") && app.ThemeChoice ~= "system"
                    theme(app.UI.Fig, char(app.ThemeChoice));
                end
            catch
                % Themes unavailable in this release; ignore.
            end
            % The image canvas stays black in every theme: that is the
            % convention for medical image display and it keeps the colour
            % limits readable against the colormap.
            app.UI.Axes.Color  = [0 0 0];
            app.UI.Axes.XColor = [0.55 0.55 0.55];
            app.UI.Axes.YColor = [0.55 0.55 0.55];
            if isfield(app.UI, 'ROITable') && isvalid(app.UI.ROITable) && ...
                    app.seriesCount() > 0
                app.refreshROITable();
            end
        end
    end

    methods (Static, Access = private)
        function cmap = resolveColormap(spec, n)
            if isnumeric(spec) && size(spec, 2) == 3
                cmap = spec;
                return
            end
            name = char(string(spec));
            try
                cmap = feval(name, n);
            catch
                cmap = gray(n);
            end
        end
    end

    %======================================================================
    % Regions of interest
    %======================================================================
    methods (Access = private)

        function idx = roisOnCurrentFrame(app)
            if isempty(app.ROIs), idx = []; return; end
            idx = find([app.ROIs.Series] == app.SeriesIndex & ...
                [app.ROIs.Frame]  == app.frameLinear());
        end

        function idx = roisInSeries(app)
            if isempty(app.ROIs), idx = []; return; end
            idx = find([app.ROIs.Series] == app.SeriesIndex);
        end

        function c = nextColor(app)
            %NEXTCOLOR  First palette colour not already in use on this frame.
            %   Counting the regions is not enough: delete the third of five
            %   and the count says four, so the next region would reuse the
            %   fifth colour. Colours already on the frame are read back
            %   instead, matching how names are chosen.
            pal = app.ROIColors;
            here = app.roisOnCurrentFrame();
            used = false(1, size(pal, 1));
            for k = here
                [d, i] = min(vecnorm(pal - double(app.ROIs(k).Color(:))', 2, 2));
                if d < 1e-6
                    used(i) = true;
                end
            end
            free = find(~used, 1);
            if isempty(free)
                % More regions than the palette holds; repetition is now
                % unavoidable, so cycle.
                free = mod(numel(here), size(pal, 1)) + 1;
            end
            c = pal(free, :);
        end

        function nm = nextROIName(app)
            %NEXTROINAME  Smallest unused roiN on the current frame.
            here = app.roisOnCurrentFrame();
            used = strings(1, numel(here));
            for i = 1:numel(here)
                used(i) = app.ROIs(here(i)).Name;
            end
            n = 1;
            while any(used == "roi" + n)
                n = n + 1;
            end
            nm = "roi" + n;
        end

        function idx = selectedROIIndices(app)
            %SELECTEDROIINDICES  ROIs whose table rows are selected right now.
            %   Read live from the table rather than cached, because
            %   reassigning the table Data clears the selection and any cache
            %   then silently disagrees with what the user sees.
            idx = [];
            t = app.UI.ROITable;
            if isempty(t.UserData) || isempty(t.Selection), return; end
            rows = unique(t.Selection(:, 1));
            rows = rows(rows >= 1 & rows <= numel(t.UserData));
            idx = reshape(t.UserData(rows), 1, []);
        end

        function idx = shownROIsOnFrame(app)
            %SHOWNROISONFRAME  ROIs on this frame with Show ticked.
            %   The Show column decides what is plotted; the table selection
            %   decides what Delete and Copy act on; the Fit region dropdown
            %   decides what is fitted. Three jobs, three separate controls.
            idx = app.roisOnCurrentFrame();
            if ~isempty(idx)
                idx = idx(arrayfun(@(k) app.ROIs(k).Visible, idx));
            end
        end

        function k = fitROIIndex(app)
            %FITROIINDEX  The ROI the fit describes: whatever the Fit region
            %   dropdown names. Deliberately independent of the table
            %   selection.
            k = [];
            shown = app.shownROIsOnFrame();
            if isempty(shown), return; end
            d = app.UI.FitROIDrop;
            if ~isempty(d.ItemsData) && ~isempty(d.Value) && ismember(d.Value, shown)
                k = d.Value;
            else
                k = shown(1);
            end
        end

        function refreshFitTargets(app)
            %REFRESHFITTARGETS  Keep the Fit region dropdown in step with the
            %   regions currently shown, preserving the choice where possible.
            d = app.UI.FitROIDrop;
            shown = app.shownROIsOnFrame();
            if isempty(shown)
                app.setChoices(d, "(no region shown)", []);
                d.Enable = 'off';
                return
            end
            nm = strings(1, numel(shown));
            for i = 1:numel(shown)
                nm(i) = app.ROIs(shown(i)).Name;
            end
            keep = shown(1);
            if ~isempty(d.ItemsData) && ~isempty(d.Value) && ismember(d.Value, shown)
                keep = d.Value;
            end
            app.setChoices(d, nm, shown, keep);
            d.Enable = 'on';
        end

        function newROI(app, shape)
            if ~app.HasIPT
                uialert(app.UI.Fig, ['Interactive ROI drawing needs Image ' ...
                    'Processing Toolbox. Use "Auto ROI by threshold" or import ' ...
                    'a mask instead.'], 'Toolbox missing');
                return
            end
            if app.MontageOn
                app.setMontage(false);
            end
            app.stopCine();
            ax = app.UI.Axes;
            col = app.nextColor();

            % Suspend our own pointer handling while the draw tool is active.
            mm = app.UI.Fig.WindowButtonMotionFcn;
            md = app.UI.Fig.WindowButtonDownFcn;
            mu = app.UI.Fig.WindowButtonUpFcn;
            app.UI.Fig.WindowButtonMotionFcn = '';
            app.UI.Fig.WindowButtonDownFcn = '';
            app.UI.Fig.WindowButtonUpFcn = '';
            app.UI.Status.Text = 'Draw the region on the image. Double-click or press Enter to finish; Esc cancels.';
            cleanup = onCleanup(@() app.restoreMouseFcns(mm, md, mu));

            try
                switch lower(shape)
                    case "polygon",   h = drawpolygon(ax,  'Color', col);
                    case "freehand",  h = drawfreehand(ax, 'Color', col);
                    case "ellipse",   h = drawellipse(ax,  'Color', col);
                    case "rectangle", h = drawrectangle(ax,'Color', col);
                    case "circle",    h = drawcircle(ax,   'Color', col);
                    case "point",     h = drawpoint(ax,    'Color', col);
                    otherwise,        h = drawpolygon(ax,  'Color', col);
                end
            catch err
                uialert(app.UI.Fig, err.message, 'Could not draw ROI');
                return
            end
            if isempty(h) || ~isvalid(h)
                app.refreshStatus();
                return
            end

            img = app.currentImage();
            mask = app.maskFromROIObject(h, size(img, 1), size(img, 2));
            pos  = app.posFromROIObject(h);
            delete(h);

            if ~any(mask(:)) && lower(string(shape)) ~= "point"
                app.refreshStatus();
                return
            end
            app.addROIRecord(mask, pos, string(shape), app.nextROIName(), col);
            app.refreshAll();
        end

        function restoreMouseFcns(app, mm, md, mu)
            if ~isvalid(app) || app.Closing || ~isvalid(app.UI.Fig), return; end
            app.UI.Fig.WindowButtonMotionFcn = mm;
            app.UI.Fig.WindowButtonDownFcn = md;
            app.UI.Fig.WindowButtonUpFcn = mu;
        end

        function k = addROIRecord(app, mask, pos, shape, name, color, si, frame)
            if nargin < 7, si = app.SeriesIndex; end
            if nargin < 8, frame = app.frameLinear(); end
            % Going from no regions to one on the visible frame is the moment
            % the pixel curve stops being the useful default. Only that
            % transition switches, so a deliberate move back to pixel mode
            % while regions exist is not overridden.
            firstHere = si == app.SeriesIndex && frame == app.frameLinear() && ...
                isempty(app.roisOnCurrentFrame()) && app.PlotMode == "pixel";
            r = struct('Series', si, 'Frame', frame, 'Name', string(name), ...
                'Shape', string(shape), 'Pos', pos, 'Mask', logical(mask), ...
                'Color', color, 'Visible', true);
            app.ROIs(end+1) = r;
            k = numel(app.ROIs);
            app.ROIsDirty = true;
            if firstHere
                app.setPlotMode("roi");
            end
        end

        function mask = maskFromROIObject(~, h, nr, nc)
            try
                mask = createMask(h, nr, nc);
            catch
                mask = false(nr, nc);
            end
            if ~any(mask(:)) && isprop(h, 'Position') && ~isempty(h.Position)
                p = round(h.Position);
                if size(p, 1) == 1 && size(p, 2) == 2
                    rr = min(nr, max(1, p(2)));
                    cc = min(nc, max(1, p(1)));
                    mask(rr, cc) = true;
                end
            end
        end

        function pos = posFromROIObject(~, h)
            pos = [];
            if isa(h, 'images.roi.Ellipse')
                pos = [h.Center, h.SemiAxes, h.RotationAngle];
            elseif isa(h, 'images.roi.Circle')
                pos = [h.Center, h.Radius];
            elseif isprop(h, 'Position')
                pos = h.Position;
            end
        end

        function h = makeLiveROI(app, k)
            r = app.ROIs(k);
            ax = app.UI.Axes;
            h = [];
            if isempty(r.Pos), return; end
            try
                switch lower(r.Shape)
                    case "polygon"
                        h = images.roi.Polygon(ax, 'Position', r.Pos, 'Color', r.Color);
                    case "freehand"
                        h = images.roi.Freehand(ax, 'Position', r.Pos, 'Color', r.Color);
                    case "ellipse"
                        h = images.roi.Ellipse(ax, 'Center', r.Pos(1:2), ...
                            'SemiAxes', r.Pos(3:4), 'RotationAngle', r.Pos(5), 'Color', r.Color);
                    case "rectangle"
                        h = images.roi.Rectangle(ax, 'Position', r.Pos, 'Color', r.Color);
                    case "circle"
                        h = images.roi.Circle(ax, 'Center', r.Pos(1:2), ...
                            'Radius', r.Pos(3), 'Color', r.Color);
                    case "point"
                        h = images.roi.Point(ax, 'Position', r.Pos, 'Color', r.Color);
                    otherwise
                        h = [];
                end
            catch
                h = [];
            end
            if ~isempty(h) && isvalid(h)
                h.Label = char(r.Name);
                h.LabelVisible = 'hover';
                app.ROIListeners{end+1} = addlistener(h, 'ROIMoved', ...
                    @(src, ~) app.onROIMoved(k, src));
                app.ROIListeners{end+1} = addlistener(h, 'DeletingROI', ...
                    @(~, ~) app.onROIDeleted(k));
            end
        end

        function onROIMoved(app, k, src)
            if k > numel(app.ROIs), return; end
            img = app.currentImage();
            app.ROIs(k).Mask = app.maskFromROIObject(src, size(img,1), size(img,2));
            app.ROIs(k).Pos  = app.posFromROIObject(src);
            app.ROIsDirty = true;
            app.refreshROITable();
            app.refreshPlot();
        end

        function onROIDeleted(app, k)
            if k > numel(app.ROIs), return; end
            app.ROIs(k) = [];
            app.ROIsDirty = true;
            app.refreshAll();
        end

        function clearLiveROIs(app)
            for i = 1:numel(app.ROIListeners)
                try
                    delete(app.ROIListeners{i});
                catch
                end
            end
            app.ROIListeners = {};
            for i = 1:numel(app.LiveROIs)
                try
                    if isvalid(app.LiveROIs{i}), delete(app.LiveROIs{i}); end
                catch
                end
            end
            app.LiveROIs = {};
            app.LiveROIIdx = [];
            if ~isempty(app.OutlineH)
                delete(app.OutlineH(isgraphics(app.OutlineH)));
            end
            app.OutlineH = gobjects(1, 0);
        end

        function refreshROIDisplay(app)
            app.clearLiveROIs();
            if app.MontageOn || app.seriesCount() == 0, return; end

            here = app.roisOnCurrentFrame();
            other = [];
            if app.ShowAllROIs
                other = setdiff(app.roisInSeries(), here);
            end

            liveBudget = 20;
            outlines = gobjects(1, 0);
            img = app.currentImage();
            nr = size(img, 1); nc = size(img, 2);

            for k = here
                r = app.ROIs(k);
                if ~r.Visible, continue; end
                drawable = app.HasIPT && ~isempty(r.Pos) && r.Shape ~= "mask" && ...
                    numel(app.LiveROIs) < liveBudget;
                if drawable
                    h = app.makeLiveROI(k);
                    if ~isempty(h) && isvalid(h)
                        app.LiveROIs{end+1} = h;
                        app.LiveROIIdx(end+1) = k;
                        continue
                    end
                end
                outlines(end+1) = app.drawOutline(r.Mask, r.Color, 1.5, nr, nc); %#ok<AGROW>
            end

            for k = other
                r = app.ROIs(k);
                if ~r.Visible, continue; end
                if size(r.Mask,1) ~= nr || size(r.Mask,2) ~= nc, continue; end
                h = app.drawOutline(r.Mask, r.Color, 0.75, nr, nc);
                h.LineStyle = ':';
                outlines(end+1) = h; %#ok<AGROW>
            end
            app.OutlineH = outlines;
        end

        function h = drawOutline(app, mask, color, lw, nr, nc)
            if isempty(mask) || size(mask,1) ~= nr || size(mask,2) ~= nc
                h = line(app.UI.Axes, NaN, NaN);
                return
            end
            [X, Y] = ImageBrowserApp.maskOutline(mask);
            h = line(app.UI.Axes, X, Y, 'Color', color, 'LineWidth', lw, ...
                'HitTest', 'off', 'PickableParts', 'none', 'Tag', 'roioutline');
        end

        %------------------------------------------------------------------
        function refreshROITable(app)
            idx = app.roisOnCurrentFrame();
            n = numel(idx);
            Show = true(n,1); Name = cell(n,1);
            N = zeros(n,1); Mean = zeros(n,1); SD = zeros(n,1);
            img = app.currentImage();
            for i = 1:n
                r = app.ROIs(idx(i));
                st = ImageBrowserApp.maskStats(img, r.Mask);
                Show(i) = r.Visible; Name{i} = char(r.Name);
                N(i) = st.N; Mean(i) = st.Mean; SD(i) = st.SD;
            end
            app.refreshFitTargets();
            % Reassigning Data cancels any cell edit in progress, so only do it
            % when the contents have actually changed.
            newData = table(Show, Name, N, Mean, SD);
            if ~isequaln(app.UI.ROITable.Data, newData)
                keep = app.selectedROIIndices();
                app.UI.ROITable.Data = newData;
                app.UI.ROITable.UserData = idx;
                rows = find(ismember(idx, keep));
                if ~isempty(rows)
                    app.UI.ROITable.Selection = rows(:);
                end
            else
                app.UI.ROITable.UserData = idx;
            end

            % Name each region in its own colour, so the table and the outlines
            % on the image can be matched at a glance.
            removeStyle(app.UI.ROITable);
            for i = 1:n
                addStyle(app.UI.ROITable, ...
                    uistyle('FontColor', app.legibleColor(app.ROIs(idx(i)).Color)), ...
                    'cell', [i 2]);
            end

            if n == 0
                app.UI.ROISummary.Text = 'No ROI on this frame.';
            else
                m = app.getROIMask(true);
                st = ImageBrowserApp.maskStats(img, m);
                app.UI.ROISummary.Text = sprintf(['All %d ROI(s) combined: %d pixels, ' ...
                    'mean %.6g, SD %.6g, median %.6g, range [%.6g %.6g]. ' ...
                    'Curves and fits use one ROI at a time.'], ...
                    n, st.N, st.Mean, st.SD, st.Median, st.Min, st.Max);
            end
        end

        function c = legibleColor(app, c)
            %LEGIBLECOLOR  Nudge a ROI colour to stay readable as table text.
            %   The palette is chosen for lines on a black image, where a pale
            %   yellow reads well; as text on a white table it does not. Hue is
            %   kept and only lightness moves, and the direction depends on the
            %   theme in force.
            c = double(c(:))';
            dark = app.ThemeChoice == "dark";
            try
                dark = strcmpi(app.UI.Fig.Theme.BaseColorStyle, 'dark');
            catch
                % Older releases expose no resolved theme; fall back to the
                % explicit choice made above.
            end
            L = 0.2126*c(1) + 0.7152*c(2) + 0.0722*c(3);
            if dark
                if L < 0.45
                    c = c + (1 - c) * (0.45 - L) / max(1 - L, eps);
                end
            elseif L > 0.55
                c = c * (0.55 / L);
            end
            c = min(1, max(0, c));
        end

        function onROITableEdit(app, e)
            idx = app.UI.ROITable.UserData;
            row = e.Indices(1); col = e.Indices(2);
            if row > numel(idx), return; end
            k = idx(row);
            switch col
                case 1
                    app.ROIs(k).Visible = logical(e.NewData);
                case 2
                    app.ROIs(k).Name = string(e.NewData);
            end
            app.ROIsDirty = true;
            % The name is carried by the live ROI object's label, so a rename
            % needs the regions redrawn, not just the table updated. Show
            % governs the plot and the fit target, and the name appears in the
            % legend, so those follow too.
            app.refreshROIDisplay();
            app.refreshFitTargets();
            app.refreshPlot();
        end

        function onROITableSelect(app, ~)
            % The selection itself lives in the table; nothing to cache here.
            app.refreshPlot();
        end

        function deleteSelectedROIs(app)
            k = app.selectedROIIndices();
            if isempty(k)
                uialert(app.UI.Fig, ['Select one or more rows in the ROI table ' ...
                    'first, then press Delete selected.'], 'Nothing selected', ...
                    'Icon', 'info');
                return
            end
            app.ROIs(k) = [];
            app.ROIsDirty = true;
            app.UI.ROITable.Selection = [];
            app.refreshAll();
        end

        function deleteFrameROIs(app)
            k = app.roisOnCurrentFrame();
            if isempty(k), return; end
            app.ROIs(k) = [];
            app.ROIsDirty = true;
            app.UI.ROITable.Selection = [];
            app.refreshAll();
        end

        function deleteSeriesROIs(app)
            k = app.roisInSeries();
            if isempty(k), return; end
            app.ROIs(k) = [];
            app.ROIsDirty = true;
            app.UI.ROITable.Selection = [];
            app.refreshAll();
        end

        function setShowAllROIs(app, tf)
            app.ShowAllROIs = logical(tf);
            app.UI.ChkSticky.Value = app.ShowAllROIs;
            app.UI.MenuSticky.Checked = matlab.lang.OnOffSwitchState(app.ShowAllROIs);
            app.refreshROIDisplay();
        end

        function toggleShowAllROIs(app)
            app.setShowAllROIs(~app.ShowAllROIs);
        end

        %------------------------------------------------------------------
        function uiAutoROI(app)
            img = app.currentImage();
            if size(img, 3) > 1
                uialert(app.UI.Fig, 'Threshold ROIs are not defined for RGB images.', 'Auto ROI');
                return
            end
            lo = double(min(img(:))); hi = double(max(img(:)));
            def = {num2str(0.9*lo + 0.1*hi), '0'};
            answer = inputdlg({sprintf('Threshold (%g - %g):', lo, hi), ...
                'Select values BELOW the threshold? (0 or 1):'}, ...
                'Auto ROI by threshold', 1, def);
            if isempty(answer), return; end
            thr = str2double(answer{1});
            if ~isfinite(thr), return; end
            below = str2double(answer{2}) == 1;
            if below
                mask = img <= thr;
            else
                mask = img >= thr;
            end
            if ~any(mask(:))
                uialert(app.UI.Fig, 'The threshold selects no pixels.', 'Auto ROI');
                return
            end
            if below
                nm = sprintf('thr<=%g', thr);
            else
                nm = sprintf('thr>=%g', thr);
            end
            app.addROIRecord(mask, [], "mask", nm, app.nextColor());
            app.refreshAll();
        end

        function uiCopyROIToFrames(app)
            sel = app.selectedROIIndices();
            if isempty(sel)
                sel = app.roisOnCurrentFrame();
            end
            if isempty(sel)
                uialert(app.UI.Fig, 'Select or create a ROI first.', 'Copy ROI');
                return
            end
            n = app.frameCount();
            answer = inputdlg({sprintf('First frame (1-%d):', n), ...
                sprintf('Last frame (1-%d):', n)}, ...
                'Copy ROI to frames', 1, {'1', num2str(n)});
            if isempty(answer), return; end
            a = max(1, min(n, round(str2double(answer{1}))));
            b = max(1, min(n, round(str2double(answer{2}))));
            if ~isfinite(a) || ~isfinite(b), return; end
            here = app.frameLinear();
            for k = sel(:)'
                r = app.ROIs(k);
                for f = min(a,b):max(a,b)
                    if f == here && r.Frame == here, continue; end
                    r2 = r; r2.Frame = f;
                    app.ROIs(end+1) = r2;
                end
            end
            app.ROIsDirty = true;
            app.refreshAll();
        end

        %------------------------------------------------------------------
        function importROIData(app, data, name)
            %IMPORTROIDATA  Accept legacy ROI formats.
            if nargin < 3, name = "imported"; end
            si = app.SeriesIndex;
            img = app.currentImage();
            nr = size(img,1); nc = size(img,2);
            nF = app.frameCount();

            if isstruct(data) && isfield(data, 'ROIs')
                names = {};
                if isfield(data, 'Names'), names = data.Names; end
                for j = 1:numel(data.ROIs)
                    if j > nF, break; end
                    R = data.ROIs{j};
                    if isempty(R), continue; end
                    for k = 1:size(R, 3)
                        m = logical(R(:,:,k));
                        if size(m,1) ~= nr || size(m,2) ~= nc, continue; end
                        if numel(names) >= j && numel(names{j}) >= k
                            nm = string(names{j}{k});
                        else
                            nm = name + j + "_" + k;
                        end
                        app.addROIRecord(m, [], "mask", nm, app.nextColor(), si, j);
                    end
                end

            elseif islogical(data) || isnumeric(data)
                data = logical(squeeze(data));
                if ismatrix(data)
                    if size(data,1) == nr && size(data,2) == nc
                        app.addROIRecord(data, [], "mask", name, app.nextColor());
                    else
                        uialert(app.UI.Fig, 'Mask size does not match the current image.', 'Import ROI');
                        return
                    end
                elseif ndims(data) == 3
                    if size(data,3) == nF
                        for j = 1:nF
                            if any(any(data(:,:,j)))
                                app.addROIRecord(data(:,:,j), [], "mask", ...
                                    name + j, app.nextColor(), si, j);
                            end
                        end
                    else
                        app.addROIRecord(data(:,:,1), [], "mask", name, app.nextColor());
                    end
                end
            end
            app.ROIsDirty = true;
            app.refreshAll();
        end
    end

    %======================================================================
    % Signal plot
    %======================================================================
    methods (Access = private)

        function configureSweep(app)
            s = app.Series(app.SeriesIndex);
            nd = numel(s.NavSize);
            items = strings(1, 0); data = zeros(1, 0);
            for k = 1:nd
                items(end+1) = sprintf('%s (1..%d)', s.DimNames(k), s.NavSize(k)); %#ok<AGROW>
                data(end+1) = k; %#ok<AGROW>
            end
            if app.seriesCount() > 1
                items(end+1) = sprintf('across series (%d)', app.seriesCount()); %#ok<AGROW>
                data(end+1) = 0; %#ok<AGROW>
            end
            if isempty(items)
                items = "(nothing to sweep)"; data = 0;
            end
            if nd >= 1
                app.SweepDim = nd;      % default: the outermost dimension
            else
                app.SweepDim = 0;
            end
            app.setChoices(app.UI.SweepDrop, items, data, app.SweepDim);
            app.resetSweepRange();
        end

        function n = sweepLength(app)
            if app.SweepDim == 0
                n = app.seriesCount();
            else
                ns = app.Series(app.SeriesIndex).NavSize;
                if app.SweepDim <= numel(ns)
                    n = ns(app.SweepDim);
                else
                    n = 1;
                end
            end
        end

        function resetSweepRange(app)
            n = max(1, app.sweepLength());
            app.PlotRange = [1 n];
            app.setRangeControl(app.UI.FromSpin, n, 1);
            app.setRangeControl(app.UI.ToSpin,   n, n);
        end

        function setSweepDim(app, k)
            app.SweepDim = k;
            app.resetSweepRange();
            app.refreshPlot();
        end

        function onRangeEdit(app)
            a = round(app.UI.FromSpin.Value);
            b = round(app.UI.ToSpin.Value);
            app.PlotRange = [min(a,b), max(a,b)];
            app.refreshPlot();
        end

        function setPlotMode(app, m)
            app.PlotMode = string(m);
            app.UI.PlotModeDrop.Value = char(app.PlotMode);
            app.refreshPlot();
        end

        function setPixelSurf(app, tf)
            app.PixelSurf = logical(tf);
            app.UI.ChkPixelSurf.Value = app.PixelSurf;
            app.UI.MenuPixelSurf.Checked = matlab.lang.OnOffSwitchState(app.PixelSurf);
            if app.PixelSurf
                app.setPlotMode("pixel");
                app.setPlotPanel(true);
            end
        end

        function togglePixelSurf(app)
            app.setPixelSurf(~app.PixelSurf);
        end

        function plotROICurve(app)
            app.setPlotMode("roi");
            app.setPlotPanel(true);
            app.refreshPlot();
        end

        function setXLabel(app, s)
            app.XLabel = string(s);
            app.UI.XLabelEdit.Value = char(app.XLabel);
            app.refreshPlot();
        end

        function clearXData(app)
            app.XData = [];
            app.setXLabel("Frame");
        end

        function updatePlotScales(app)
            ax = app.UI.PlotAxes;
            if app.UI.ChkLogY.Value, ax.YScale = 'log'; else, ax.YScale = 'linear'; end
            if app.UI.ChkLogX.Value, ax.XScale = 'log'; else, ax.XScale = 'linear'; end
            app.refreshPlot();
        end

        %------------------------------------------------------------------
        function [x, y, sd] = sweepValues(app, mask, pix)
            %SWEEPVALUES  Signal along the sweep dimension.
            %   Give a logical MASK for a region mean, or a [row col] PIX for a
            %   single voxel. Exactly one of the two.
            x = []; y = []; sd = [];
            if app.seriesCount() == 0, return; end
            n = app.sweepLength();
            a = max(1, min(n, app.PlotRange(1)));
            b = max(1, min(n, app.PlotRange(2)));
            k = a:b;
            if isempty(k), return; end

            y  = nan(1, numel(k));
            sd = nan(1, numel(k));
            for i = 1:numel(k)
                img = app.sweepImage(k(i));
                if isempty(img), continue; end
                if size(img, 3) > 1, img = mean(double(img), 3); end
                if isempty(mask)
                    if pix(1) <= size(img,1) && pix(2) <= size(img,2)
                        y(i) = double(img(pix(1), pix(2)));
                    end
                else
                    if size(img,1) == size(mask,1) && size(img,2) == size(mask,2)
                        st = ImageBrowserApp.maskStats(img, mask);
                        y(i) = st.Mean; sd(i) = st.SD;
                    end
                end
            end

            x = double(k);
            if ~isempty(app.XData)
                if numel(app.XData) == numel(k)
                    x = app.XData(:)';
                elseif numel(app.XData) >= max(k)
                    x = app.XData(k);
                end
            end
        end

        function [x, y, sd, lbl, col] = sweepCurve(app)
            %SWEEPCURVE  The one curve that analysis acts on.
            %   In pixel mode that is the voxel under the cursor. In ROI mode
            %   it is the single selected ROI - regions are never combined,
            %   because a fit to a union of unrelated regions means nothing.
            x = []; y = []; sd = []; lbl = ""; col = [0 0.447 0.741];
            if app.seriesCount() == 0, return; end

            if app.PlotMode == "roi"
                k = app.fitROIIndex();
                if isempty(k)
                    if isempty(app.roisOnCurrentFrame())
                        lbl = "no ROI on this frame";
                    else
                        lbl = "select exactly one ROI in the table";
                    end
                    return
                end
                [x, y, sd] = app.sweepValues(app.ROIs(k).Mask, []);
                col = app.ROIs(k).Color;
                lbl = sprintf('%s over %s', app.ROIs(k).Name, app.sweepName());
            else
                pix = app.LastPixel;
                if ~all(isfinite(pix))
                    lbl = "move the pointer over the image";
                    return
                end
                [x, y, sd] = app.sweepValues([], pix);
                lbl = sprintf('pixel (%d,%d) over %s', pix(1), pix(2), app.sweepName());
            end
        end

        function nm = sweepName(app)
            if app.SweepDim == 0
                nm = 'series';
            else
                s = app.Series(app.SeriesIndex);
                nm = char(s.DimNames(min(app.SweepDim, numel(s.DimNames))));
            end
        end

        function img = sweepImage(app, k)
            img = [];
            if app.SweepDim == 0
                if k <= app.seriesCount()
                    s2 = app.Series(k);
                    f = min(app.frameLinear(), max(1, prod([s2.NavSize 1])));
                    img = app.imageAt(k, f);
                end
            else
                sub = app.Sub;
                if app.SweepDim <= numel(sub)
                    sub(app.SweepDim) = k;
                    img = app.imageAtSub(app.SeriesIndex, sub);
                end
            end
        end

        %------------------------------------------------------------------
        function clearRoiCurves(app)
            h = app.RoiLines;
            if ~isempty(h)
                delete(h(isgraphics(h)));
            end
            app.RoiLines = gobjects(1, 0);
        end

        function refreshLegend(app, ax)
            %REFRESHLEGEND  List every curve actually on screen: the data, the
            %   fitted model and any plotted function. Built after all three
            %   are drawn, so a fit is named even when a single region is shown.
            h = gobjects(1, 0);
            if app.PlotMode == "roi"
                h = app.RoiLines;
            elseif logical(app.UI.PlotLine.Visible)
                h = app.UI.PlotLine;
            end
            if any(isfinite(app.UI.PlotFit.XData)), h(end+1) = app.UI.PlotFit; end
            if any(isfinite(app.UI.PlotFun.XData)), h(end+1) = app.UI.PlotFun; end
            if numel(h) > 1
                legend(ax, h, 'Location', 'best', 'Box', 'off', 'FontSize', 8);
            else
                legend(ax, 'off');
            end
        end

        function blankPlot(app, msg)
            app.UI.PlotLine.Visible = 'off';
            app.UI.PlotBand.XData = NaN; app.UI.PlotBand.YData = NaN;
            app.UI.PlotFit.XData  = NaN; app.UI.PlotFit.YData  = NaN;
            app.UI.PlotFun.XData  = NaN; app.UI.PlotFun.YData  = NaN;
            legend(app.UI.PlotAxes, 'off');
            app.UI.PlotInfo.Text = char(msg);
            title(app.UI.PlotAxes, char(msg));
            app.UI.Fig.UserData = [];
        end

        function refreshPlot(app)
            if ~isfield(app.UI, 'PlotAxes') || ~isvalid(app.UI.PlotAxes), return; end
            if ~logical(app.UI.PlotPanel.Visible), return; end
            ax = app.UI.PlotAxes;
            app.clearRoiCurves();
            app.UI.PlotLine.Visible = 'off';
            app.UI.PlotBand.XData = NaN; app.UI.PlotBand.YData = NaN;

            if app.PlotMode == "roi"
                % One curve per visible ROI, drawn in that ROI's own colour.
                idx = app.shownROIsOnFrame();
                if isempty(idx)
                    if isempty(app.roisOnCurrentFrame())
                        app.blankPlot('No ROI on this frame.');
                    else
                        app.blankPlot('No ROI is ticked in the Show column.');
                    end
                    return
                end
                names = strings(1, 0);
                X = []; Y = []; SD = [];
                for k = idx
                    [xk, yk, sdk] = app.sweepValues(app.ROIs(k).Mask, []);
                    if isempty(xk) || all(isnan(yk)), continue; end
                    yy = yk;
                    if app.UI.ChkLogY.Value, yy = abs(yy); end
                    h = plot(ax, xk, yy, 'o-', 'LineWidth', 1.2, 'MarkerSize', 4, ...
                        'Color', app.ROIs(k).Color, ...
                        'DisplayName', char(app.ROIs(k).Name));
                    app.RoiLines(end+1) = h;
                    names(end+1) = app.ROIs(k).Name; %#ok<AGROW>
                    X = xk; Y = [Y; yk]; SD = [SD; sdk]; %#ok<AGROW>
                end
                if isempty(app.RoiLines)
                    app.blankPlot('No usable ROI curve.');
                    return
                end

                % The spread band would be unreadable over several curves.
                if numel(app.RoiLines) == 1 && app.UI.ChkSD.Value && any(isfinite(SD))
                    good = isfinite(Y) & isfinite(SD);
                    app.UI.PlotBand.XData = [X(good), fliplr(X(good))];
                    app.UI.PlotBand.YData = [Y(good) + SD(good), fliplr(Y(good) - SD(good))];
                    app.UI.PlotBand.FaceColor = app.RoiLines(1).Color;
                    uistack(app.UI.PlotBand, 'bottom');
                end
                if numel(app.RoiLines) > 1
                    lbl = sprintf('%d ROIs over %s', numel(app.RoiLines), app.sweepName());
                else
                    lbl = sprintf('%s over %s', names(1), app.sweepName());
                end
                x = X; y = Y; sd = SD;
            else
                [x, y, sd, lbl] = app.sweepCurve();
                if isempty(x) || all(isnan(y))
                    app.blankPlot(lbl);
                    return
                end
                yy = y;
                if app.UI.ChkLogY.Value, yy = abs(yy); end
                app.UI.PlotLine.Visible = 'on';
                app.UI.PlotLine.XData = x;
                app.UI.PlotLine.YData = yy;
                app.UI.PlotLine.DisplayName = sprintf('pixel (%d,%d)', ...
                    app.LastPixel(1), app.LastPixel(2));
                names = "pixel";
            end

            app.drawFunOverlay(x);
            app.drawFitCurve();
            app.refreshLegend(ax);

            xlabel(ax, char(app.XLabel));
            ylabel(ax, 'Signal');
            title(ax, char(lbl));
            app.UI.PlotInfo.Text = sprintf('%s\n%d point(s), mean %.6g', lbl, ...
                sum(isfinite(y(1,:))), mean(y(1,:), 'omitnan'));
            app.UI.Fig.UserData = struct('x', x, 'y', y, 'sd', sd, ...
                'names', names, 'label', string(lbl));
        end

        function drawFunOverlay(app, x)
            app.UI.PlotFun.XData = NaN;
            app.UI.PlotFun.YData = NaN;
            if isempty(app.FunSpec.Fun), return; end
            try
                xf = app.FunSpec.X;
                if isempty(xf), xf = x; end
                yf = app.FunSpec.Fun(app.FunSpec.Par, xf);
                app.UI.PlotFun.XData = xf(:)';
                app.UI.PlotFun.YData = yf(:)';
            catch
                % A stale specification; simply do not draw it.
            end
        end

        function clearPlottedFunction(app)
            app.FunSpec = struct('Fun', [], 'X', [], 'Par', []);
            app.refreshPlot();
        end

        function uiPlotFunction(app)
            %UIPLOTFUNCTION  Overlay f(par, x) using parameters you supply.
            %   This draws a curve; it does not estimate anything. Use the
            %   diffusion fit for parameter estimation.
            answer = inputdlg({ ...
                'Function name, called as f(par, x):', ...
                'Parameter expression, evaluated in the base workspace:', ...
                'x expression, evaluated in the base workspace (blank = plot x-axis):'}, ...
                'Plot a function', 1, {'', '', ''});
            if isempty(answer), return; end
            fname = strtrim(answer{1});
            if isempty(fname), return; end
            if isempty(which(fname))
                uialert(app.UI.Fig, sprintf(['No function named "%s" is on the path. ' ...
                    'It must be a file, not a handle in your workspace.'], fname), ...
                    'Plot a function');
                return
            end
            try
                par = evalin('base', answer{2});
                if isempty(strtrim(answer{3}))
                    xf = [];
                else
                    xf = evalin('base', answer{3});
                end
            catch err
                uialert(app.UI.Fig, err.message, 'Plot a function');
                return
            end
            app.FunSpec = struct('Fun', str2func(fname), 'X', xf, 'Par', par);
            app.setPlotPanel(true);
            app.refreshPlot();
        end

        %------------------------------------------------------------------
        % Diffusion fitting
        %------------------------------------------------------------------
        function drawFitCurve(app)
            app.UI.PlotFit.XData = NaN;
            app.UI.PlotFit.YData = NaN;
            if ~isfield(app.FitResult, 'P') || isempty(app.FitResult.P), return; end
            r = app.FitResult;
            xg = linspace(min(r.B), max(r.B), 200);
            yg = ImageBrowserApp.dkiSignal(r.P, xg, r.Model);
            app.UI.PlotFit.XData = xg;
            app.UI.PlotFit.YData = yg(:)';
            if isfield(r, 'Color') && ~isempty(r.Color)
                % Same colour as the region it describes, dashed and without
                % markers so it stays distinguishable from the data.
                app.UI.PlotFit.Color = r.Color;
            end
            app.UI.PlotFit.LineStyle = '--';
            if isfield(r, 'Region') && strlength(string(r.Region)) > 0
                app.UI.PlotFit.DisplayName = char(r.Model + " fit " + r.Region);
            else
                app.UI.PlotFit.DisplayName = char(r.Model + " fit");
            end
        end

        function clearFit(app)
            app.FitResult = struct();
            app.UI.FitInfo.Text = 'No fit yet.';
            app.refreshPlot();
        end

        function uiFitDiffusion(app)
            app.setPlotPanel(true);
            [x, y, ~, lbl, col] = app.sweepCurve();
            if isempty(x) || all(isnan(y))
                if app.PlotMode == "roi"
                    if isempty(app.roisOnCurrentFrame())
                        msg = 'Draw a ROI on this frame first.';
                    else
                        msg = ['No region is ticked in the Show column, so there ' ...
                               'is nothing to fit.'];
                    end
                else
                    msg = ['Click a pixel on the image first, or set Plot to ' ...
                           '"ROI mean".'];
                end
                uialert(app.UI.Fig, msg, 'Diffusion fit');
                return
            end
            if isempty(app.XData)
                choice = uiconfirm(app.UI.Fig, ['The x-axis holds frame indices, not ' ...
                    'b-values, so D and K would be in units of "per frame". Fit anyway?'], ...
                    'No b-values set', 'Options', {'Fit anyway', 'Cancel'}, ...
                    'DefaultOption', 2, 'CancelOption', 2);
                if ~strcmp(choice, 'Fit anyway'), return; end
            end

            model = string(app.UI.FitModelDrop.Value);
            try
                r = ImageBrowserApp.fitDiffusion(x, y, model, ...
                    app.UI.FitWeighted.Value, app.UI.FitRefine.Value);
            catch err
                uialert(app.UI.Fig, err.message, 'Diffusion fit');
                return
            end
            r.Label = string(lbl);
            r.Color = col;
            if app.PlotMode == "roi"
                kFit = app.fitROIIndex();
                if isempty(kFit)
                    r.Region = "";
                else
                    r.Region = app.ROIs(kFit).Name;
                end
            else
                r.Region = sprintf('pixel (%d,%d)', app.LastPixel(1), app.LastPixel(2));
            end
            app.FitResult = r;
            app.UI.FitInfo.Text = ImageBrowserApp.formatFit(r);
            app.refreshPlot();
        end

        function uiExportFit(app)
            if ~isfield(app.FitResult, 'P') || isempty(app.FitResult.P)
                uialert(app.UI.Fig, 'There is no fit to export.', 'Export fit');
                return
            end
            name = app.askName('Variable name for the fit result:', 'fitResult');
            if isempty(name), return; end
            assignin('base', name, app.FitResult);
        end
    end

    methods (Static)
        function [F, J] = dkiSignal(p, b, model)
            %DKISIGNAL  Diffusion kurtosis signal and its analytic Jacobian.
            %
            %   S(b) = S0 * exp(-b*D + b^2*D^2*K/6)
            %
            %   with p = [S0 D K] for model "DKI", and p = [S0 D] for model
            %   "DTI", which is the K = 0 special case fitted as a genuine
            %   two-parameter problem rather than a constrained three.
            %
            %   The second output is the n-by-numel(p) Jacobian dS/dp, which
            %   lsqcurvefit consumes when SpecifyObjectiveGradient is true.
            if nargin < 3, model = "DKI"; end
            b = double(b(:));
            S0 = p(1); D = p(2);
            if string(model) == "DKI"
                K = p(3);
                E = exp(-b*D + (1/6) * b.^2 * D^2 * K);
                F = S0 * E;
                if nargout > 1
                    J = [E, F .* (-b + (1/3) * b.^2 * D * K), F .* ((1/6) * b.^2 * D^2)];
                end
            else
                E = exp(-b*D);
                F = S0 * E;
                if nargout > 1
                    J = [E, -b .* F];
                end
            end
        end

        function r = fitDiffusion(b, S, model, weighted, refine)
            %FITDIFFUSION  Fit S0, D and (for DKI) K to a single 1-D curve.
            %
            %   Stage 1 is a linear least-squares fit to log(S), which needs no
            %   starting values. Because log-transforming makes the noise
            %   heteroscedastic - var(log S) is about var(S)/S^2 - the rows are
            %   optionally scaled by S, which restores approximately uniform
            %   weighting. Stage 2 refines those estimates with lsqcurvefit on
            %   the untransformed signal, using the analytic Jacobian above.
            %
            %   The reported standard errors come from the linearised
            %   covariance sigma^2 * inv(J'*J) at the solution. They assume
            %   independent Gaussian noise, which magnitude MRI violates at low
            %   SNR, so treat them as indicative rather than exact.
            arguments
                b (1,:) double
                S (1,:) double
                model (1,1) string = "DKI"
                weighted (1,1) logical = true
                refine (1,1) logical = true
            end
            model = upper(model);
            if ~ismember(model, ["DTI" "DKI"])
                error('ImageBrowser:badModel', 'Model must be "DTI" or "DKI".');
            end
            np = 2 + double(model == "DKI");

            b = b(:); S = S(:);
            good = isfinite(b) & isfinite(S);
            pos  = good & S > 0;
            if nnz(pos) < np
                error('ImageBrowser:tooFewPoints', ...
                    ['Only %d usable points with S > 0; the %s model needs at ' ...
                    'least %d.'], nnz(pos), model, np);
            end

            % --- stage 1: linear least squares on log(S) ----------------------
            bl = b(pos); Sl = S(pos);
            if model == "DKI"
                A = [ones(numel(bl),1), bl, bl.^2];
            else
                A = [ones(numel(bl),1), bl];
            end
            yl = log(Sl);
            if weighted
                w = Sl;                      % var(log S) ~ 1/S^2
                c = (w .* A) \ (w .* yl);
            else
                c = A \ yl;
            end

            S0 = exp(c(1));
            D  = -c(2);
            if ~isfinite(D) || D <= 0
                D = 1e-4;                    % keep the starting point feasible
            end
            if model == "DKI"
                K = 6 * c(3) / D^2;
                if ~isfinite(K), K = 0; end
                K = min(max(K, -1), 5);      % clamp the starting point only
                p0 = [S0 D K];
            else
                p0 = [S0 D];
            end

            r = struct();
            r.Model    = model;
            r.Init     = p0;
            r.B        = b(good)';
            r.S        = S(good)';
            r.Weighted = weighted;
            r.Refined  = false;
            r.ExitFlag = NaN;
            r.SE       = nan(1, np);

            % --- stage 2: nonlinear least squares on S ------------------------
            p = p0;
            bf = b(good); Sf = S(good);
            if refine && isempty(which('lsqcurvefit'))
                warning('ImageBrowser:noOptimToolbox', ...
                    ['Optimization Toolbox not found; reporting the log-linear ' ...
                    'estimate without nonlinear refinement.']);
                refine = false;
            end
            if refine
                lb = [0 0 -Inf]; ub = [Inf Inf Inf];
                fun = @(pp, bb) ImageBrowserApp.dkiSignal(pp, bb, model);
                opts = optimoptions('lsqcurvefit', ...
                    'SpecifyObjectiveGradient', true, 'Display', 'off', ...
                    'FunctionTolerance', 1e-12, 'StepTolerance', 1e-12, ...
                    'MaxFunctionEvaluations', 2000);
                [p, resnorm, ~, exitflag, ~, ~, J] = ...
                    lsqcurvefit(fun, p0, bf, Sf, lb(1:np), ub(1:np), opts);
                p = p(:)';
                r.Refined = true;
                r.ExitFlag = exitflag;
                dof = numel(bf) - np;
                if dof > 0
                    try
                        Jf = full(J);
                        [~, R] = qr(Jf, 0);
                        Rinv = R \ eye(np);
                        r.SE = sqrt(abs(diag((resnorm / dof) * (Rinv * Rinv'))))';
                    catch
                        r.SE = nan(1, np);
                    end
                end
            end

            % --- summary ------------------------------------------------------
            pred = ImageBrowserApp.dkiSignal(p, bf, model);
            res  = Sf - pred;
            r.P     = p;
            r.S0    = p(1);
            r.D     = p(2);
            if model == "DKI", r.K = p(3); else, r.K = 0; end
            r.N     = numel(bf);
            r.RMSE  = sqrt(mean(res.^2));
            sst     = sum((Sf - mean(Sf)).^2);
            if sst > 0
                r.R2 = 1 - sum(res.^2) / sst;
            else
                r.R2 = NaN;
            end
            if model == "DKI"
                r.Names = ["S0" "D" "K"];
            else
                r.Names = ["S0" "D"];
            end
        end

        function txt = formatFit(r)
            %FORMATFIT  Human-readable summary of a fitDiffusion result.
            L = strings(0,1);
            how = "log-linear";
            if r.Refined, how = "log-linear then nonlinear"; end
            L(end+1) = sprintf('%s, %d points, %s', r.Model, r.N, how);
            L(end+1) = sprintf('S0 = %.4g%s', r.S0, ImageBrowserApp.pm(r.SE, 1));
            L(end+1) = sprintf('D  = %.4g%s mm^2/s', r.D, ImageBrowserApp.pm(r.SE, 2));
            L(end+1) = sprintf('     %.4g um^2/ms', r.D * 1e3);
            if r.Model == "DKI"
                L(end+1) = sprintf('K  = %.4g%s', r.K, ImageBrowserApp.pm(r.SE, 3));
            end
            L(end+1) = sprintf('RMSE = %.4g   R2 = %.5f', r.RMSE, r.R2);
            if r.Refined && r.ExitFlag <= 0
                L(end+1) = sprintf('WARNING: solver exit flag %d', r.ExitFlag);
            end
            if r.D <= 0 || r.S0 <= 0
                L(end+1) = 'WARNING: a parameter sits on its bound';
            end
            txt = char(join(L, newline));
        end

        function s = pm(se, k)
            if numel(se) >= k && isfinite(se(k))
                s = sprintf(' +/- %.3g', se(k));
            else
                s = '';
            end
        end
    end

    methods (Access = private)

        function uiSetXData(app)
            [name, ok] = app.pickWorkspaceVariable({'double','single','int8','int16', ...
                'int32','int64','uint8','uint16','uint32','uint64'}, ...
                'Choose the x-axis variable');
            if ~ok, return; end
            x = evalin('base', name);
            if ~isnumeric(x) || ~isvector(x)
                uialert(app.UI.Fig, 'The x-axis variable must be a numeric vector.', 'Set x-axis');
                return
            end
            app.XData = double(x(:))';
            n = app.sweepLength();
            if numel(app.XData) ~= n
                uialert(app.UI.Fig, sprintf(['The variable has %d elements but the ' ...
                    'current sweep has %d. It will be indexed by frame number where ' ...
                    'possible.'], numel(app.XData), n), 'Set x-axis', 'Icon', 'warning');
            end
            app.setXLabel(string(name));
        end
    end

    %======================================================================
    % Overlay controls
    %======================================================================
    methods (Access = private)

        function setOverlayEnabled(app, tf)
            app.Overlay.Enabled = logical(tf) && ~isempty(app.Overlay.Data);
            app.UI.ChkOverlay.Value = app.Overlay.Enabled;
            app.refreshImage();
        end

        function setOverlayCmap(app, name)
            app.Overlay.Colormap = string(name);
            app.refreshImage();
        end

        function setOverlayAlpha(app, a)
            app.Overlay.Alpha = a;
            app.refreshImage();
        end

        function setOverlayThreshold(app, t)
            app.Overlay.Threshold = t;
            app.refreshImage();
        end

        function setActiveLayer(app, layer)
            app.ActiveLayer = string(layer);
            app.UI.LayerDrop.Value = char(app.ActiveLayer);
            app.syncCLimControls();
        end

        function syncOverlayControls(app)
            app.UI.ChkOverlay.Value = app.Overlay.Enabled;
            app.UI.OvAlpha.Value = app.Overlay.Alpha;
            if isfinite(app.Overlay.Threshold)
                app.UI.OvThresh.Value = app.Overlay.Threshold;
            end
            if any(strcmp(app.UI.OvCmap.Items, char(app.Overlay.Colormap)))
                app.UI.OvCmap.Value = char(app.Overlay.Colormap);
            end
        end

        function uiLoadOverlay(app)
            [name, ok] = app.pickWorkspaceVariable({}, 'Choose the overlay variable');
            if ~ok, return; end
            v = evalin('base', name);
            if ~isnumeric(v) && ~islogical(v)
                uialert(app.UI.Fig, 'The overlay must be a numeric or logical array.', 'Overlay');
                return
            end
            img = app.currentImage();
            if size(v,1) ~= size(img,1) || size(v,2) ~= size(img,2)
                uialert(app.UI.Fig, sprintf(['The overlay is %dx%d but the current ' ...
                    'image is %dx%d.'], size(v,1), size(v,2), size(img,1), size(img,2)), ...
                    'Overlay');
                return
            end
            app.setOverlay(double(v), 'Colormap', string(app.UI.OvCmap.Value), ...
                'Alpha', app.UI.OvAlpha.Value);
            app.setOverlayEnabled(true);
        end
    end

    %======================================================================
    % Import and export
    %======================================================================
    methods (Access = private)

        function [name, ok] = pickWorkspaceVariable(app, classes, prompt)
            name = ''; ok = false;
            w = evalin('base', 'whos');
            if ~isempty(classes)
                keep = ismember({w.class}, classes);
                w = w(keep);
            end
            if isempty(w)
                uialert(app.UI.Fig, 'No suitable variables in the base workspace.', prompt);
                return
            end
            items = cell(1, numel(w));
            for k = 1:numel(w)
                items{k} = sprintf('%s   (%s %s)', w(k).name, ...
                    mat2str(w(k).size), w(k).class);
            end
            [sel, tf] = listdlg('Name', 'Base workspace', 'PromptString', prompt, ...
                'SelectionMode', 'single', 'ListString', items, 'ListSize', [340 300]);
            if ~tf, return; end
            name = w(sel).name;
            ok = true;
        end

        function uiImportImage(app)
            [name, ok] = app.pickWorkspaceVariable({}, 'Choose an image variable');
            if ~ok, return; end
            v = evalin('base', name);
            n0 = app.seriesCount();
            app.addSeries(v, string(name));
            if app.seriesCount() > n0
                app.selectSeries(n0 + 1);
            end
        end

        function uiImportROI(app)
            [name, ok] = app.pickWorkspaceVariable({'logical','double','single','struct'}, ...
                'Choose a ROI variable (mask or ROI sequence)');
            if ~ok, return; end
            v = evalin('base', name);
            app.importROIData(v, string(name));
        end

        function uiImportFile(app)
            [f, p] = uigetfile({'*.png;*.tif;*.tiff;*.jpg;*.jpeg;*.bmp;*.mat', ...
                'Images and MAT-files'; '*.*', 'All files'}, 'Import image');
            if isequal(f, 0), return; end
            full = fullfile(p, f);
            [~, base, ext] = fileparts(full);
            try
                if strcmpi(ext, '.mat')
                    S = load(full);
                    app.addSeries(S, string(base));
                else
                    app.addSeries(imread(full), string(base));
                end
            catch err
                uialert(app.UI.Fig, err.message, 'Import failed');
                return
            end
            app.selectSeries(app.seriesCount());
        end

        function uiImport2dseq(app)
            [f, p] = uigetfile({'2dseq;*.*', 'Bruker 2dseq'}, 'Import Bruker 2dseq');
            if isequal(f, 0), return; end
            answer = inputdlg({'Array size, e.g. [128 128 30 163]:', ...
                'Binary precision, e.g. int16:'}, 'Read 2dseq', 1, ...
                {'[128 128]', 'int16'});
            if isempty(answer), return; end
            try
                sz = str2num(answer{1}); %#ok<ST2NM>
                data = ImageBrowserApp.read2dseq(fullfile(p, f), sz, strtrim(answer{2}));
            catch err
                uialert(app.UI.Fig, err.message, 'Import failed');
                return
            end
            app.addSeries(data, "2dseq");
            app.selectSeries(app.seriesCount());
        end

        %------------------------------------------------------------------
        function uiExportImage(app)
            [f, p] = uiputfile({'*.png';'*.tif';'*.pdf';'*.eps'}, 'Export current view', ...
                'image.png');
            if isequal(f, 0), return; end
            try
                exportgraphics(app.UI.Axes, fullfile(p, f), 'Resolution', 300);
            catch err
                uialert(app.UI.Fig, err.message, 'Export failed');
            end
        end

        function uiExportImageToWS(app)
            name = app.askName('Variable name for the current image:', 'currentImage');
            if isempty(name), return; end
            assignin('base', name, app.currentImage());
        end

        function uiExportApp(app)
            [f, p] = uiputfile({'*.png';'*.pdf'}, 'Save a snapshot of the app', 'imagebrowser.png');
            if isequal(f, 0), return; end
            try
                exportapp(app.UI.Fig, fullfile(p, f));
            catch err
                uialert(app.UI.Fig, err.message, 'Export failed');
            end
        end

        function uiExportCine(app)
            k = app.cineDim();
            ns = app.Series(app.SeriesIndex).NavSize;
            if isempty(ns) || ns(k) < 2
                uialert(app.UI.Fig, 'This series has only one frame along the cine dimension.', 'Export cine');
                return
            end
            [f, p] = uiputfile({'*.gif', 'Animated GIF'; '*.mp4', 'MPEG-4'}, ...
                'Export cine', 'cine.gif');
            if isequal(f, 0), return; end
            full = fullfile(p, f);
            [~, ~, ext] = fileparts(full);
            n = ns(k);
            cmap = ImageBrowserApp.resolveColormap(app.CmapName, 256);
            if app.CmapInvert, cmap = flipud(cmap); end
            lim = app.CLimStore;
            d = uiprogressdlg(app.UI.Fig, 'Title', 'Exporting cine', 'Indeterminate', 'off');
            cleanup = onCleanup(@() delete(d)); %#ok<NASGU>
            try
                if strcmpi(ext, '.mp4')
                    vw = VideoWriter(full, 'MPEG-4');
                    vw.FrameRate = app.CineFPS;
                    open(vw);
                end
                for i = 1:n
                    d.Value = i / n;
                    sub = app.Sub; sub(k) = i;
                    img = app.imageAtSub(app.SeriesIndex, sub);
                    idx = ImageBrowserApp.toIndexed(img, lim, size(cmap, 1));
                    if strcmpi(ext, '.mp4')
                        writeVideo(vw, im2frame(idx, cmap));
                    else
                        if i == 1
                            imwrite(idx, cmap, full, 'gif', 'LoopCount', Inf, ...
                                'DelayTime', 1 / app.CineFPS);
                        else
                            imwrite(idx, cmap, full, 'gif', 'WriteMode', 'append', ...
                                'DelayTime', 1 / app.CineFPS);
                        end
                    end
                end
                if strcmpi(ext, '.mp4'), close(vw); end
            catch err
                uialert(app.UI.Fig, err.message, 'Export failed');
            end
        end

        %------------------------------------------------------------------
        function uiExportROIMask(app)
            name = app.askName('Variable name for the ROI mask:', 'roi');
            if isempty(name), return; end
            assignin('base', name, app.getROIMask(true));
        end

        function ok = uiExportROISeq(app)
            ok = false;
            name = app.askName('Variable name for the ROI sequence:', 'ROIseq');
            if isempty(name), return; end
            assignin('base', name, app.buildROISeq());
            app.ROIsDirty = false;
            ok = true;
        end

        function seq = buildROISeq(app)
            %BUILDROISEQ  ROI sequence in the layout used by the original app,
            %   so that existing downstream scripts keep working.
            nF = app.frameCount();
            img = app.currentImage();
            nr = size(img,1); nc = size(img,2);
            seq.ROIs  = cell(1, nF);
            seq.Names = cell(1, nF);
            for j = 1:nF
                k = find([app.ROIs.Series] == app.SeriesIndex & [app.ROIs.Frame] == j);
                M = false(nr, nc, numel(k));
                nm = cell(1, numel(k));
                for i = 1:numel(k)
                    m = app.ROIs(k(i)).Mask;
                    if size(m,1) == nr && size(m,2) == nc
                        M(:,:,i) = m;
                    end
                    nm{i} = char(app.ROIs(k(i)).Name);
                end
                seq.ROIs{j}  = M;
                seq.Names{j} = nm;
            end
        end

        function uiExportROIStatsWS(app)
            name = app.askName(['Variable name for the ROI measurements ' ...
                '(a table is written, plus <name>_legacy in the old struct layout):'], 'ROIstats');
            if isempty(name), return; end
            assignin('base', name, app.roiStats());
            assignin('base', [name '_legacy'], app.legacyROIStats());
            app.ROIsDirty = false;
        end

        function temp = legacyROIStats(app)
            nF = app.frameCount();
            temp = struct('Means', {}, 'Std', {}, 'Names', {}, 'ROIvals', {});
            for j = 1:nF
                k = find([app.ROIs.Series] == app.SeriesIndex & [app.ROIs.Frame] == j);
                img = app.imageAt(app.SeriesIndex, j);
                temp(j).Means = []; temp(j).Std = [];
                temp(j).Names = {}; temp(j).ROIvals = {};
                for i = 1:numel(k)
                    m = app.ROIs(k(i)).Mask;
                    if size(m,1) ~= size(img,1) || size(m,2) ~= size(img,2), continue; end
                    v = double(img(m));
                    temp(j).Means(end+1)   = mean(v, 'omitnan');
                    temp(j).Std(end+1)     = std(v, 'omitnan');
                    temp(j).Names{end+1}   = char(app.ROIs(k(i)).Name);
                    temp(j).ROIvals{end+1} = v;
                end
            end
        end

        function uiExportROIStatsCSV(app)
            T = app.roiStats();
            if isempty(T)
                uialert(app.UI.Fig, 'There are no ROIs to export.', 'Export');
                return
            end
            [f, p] = uiputfile({'*.csv'}, 'Export ROI statistics', 'roistats.csv');
            if isequal(f, 0), return; end
            writetable(T, fullfile(p, f));
            app.ROIsDirty = false;
        end

        function uiExportPlotData(app)
            d = app.UI.Fig.UserData;
            if isempty(d) || ~isstruct(d) || ~isfield(d, 'x') || isempty(d.x)
                uialert(app.UI.Fig, 'There is no plotted curve to export.', 'Export');
                return
            end
            T = app.plotDataTable(d);
            choice = uiconfirm(app.UI.Fig, 'Where should the curve go?', ...
                'Export plot data', 'Options', {'Workspace', 'CSV file', 'Cancel'}, ...
                'DefaultOption', 1, 'CancelOption', 3);
            switch choice
                case 'Workspace'
                    name = app.askName('Variable name for the plotted curve(s):', 'curve');
                    if isempty(name), return; end
                    assignin('base', name, T);
                case 'CSV file'
                    [f, pth] = uiputfile({'*.csv'}, 'Export curve', 'curve.csv');
                    if isequal(f, 0), return; end
                    writetable(T, fullfile(pth, f));
            end
        end

        function T = plotDataTable(~, d)
            %PLOTDATATABLE  One x column plus a y (and sd) column per curve.
            T = table(d.x(:), 'VariableNames', {'x'});
            for i = 1:size(d.y, 1)
                if i <= numel(d.names)
                    tag = d.names(i);
                else
                    tag = "curve" + i;
                end
                T.(char(matlab.lang.makeValidName("y_" + tag))) = d.y(i, :)';
                if any(isfinite(d.sd(i, :)))
                    T.(char(matlab.lang.makeValidName("sd_" + tag))) = d.sd(i, :)';
                end
            end
        end

        function name = askName(app, prompt, default)
            answer = inputdlg(prompt, 'Name', 1, {default});
            name = '';
            if isempty(answer), return; end
            candidate = matlab.lang.makeValidName(strtrim(answer{1}));
            if isempty(candidate), return; end
            name = char(candidate);
        end

        %------------------------------------------------------------------
        function uiModifyCLim(app)
            lim = app.activeCLim();
            answer = inputdlg({'Lower colour limit:', 'Upper colour limit:'}, ...
                'Modify colour limits', 1, {num2str(lim(1)), num2str(lim(2))});
            if isempty(answer), return; end
            a = str2double(answer{1}); b = str2double(answer{2});
            if ~isfinite(a) || ~isfinite(b), return; end
            app.CLimMode = "manual";
            app.UI.CLimModeDrop.Value = 'manual';
            app.setCLim([a b]);
        end

        function showShortcuts(app)
            msg = {
                'Left / Right arrow      previous / next frame'
                'Page Up / Page Down     step 10 frames'
                'Home / End              first / last frame'
                'Up / Down arrow         previous / next series'
                'Space                   play / pause the cine loop'
                'Scroll wheel            change frame'
                'Ctrl + scroll wheel     zoom about the pointer'
                'Right-drag on image     window / level'
                'C                       toggle the colorbar'
                'L                       lock the colour limits'
                'R                       reset the colour limits'
                'M                       toggle montage view'
                };
            uialert(app.UI.Fig, msg, 'Keyboard and mouse', 'Icon', 'info');
        end

        function showAbout(app)
            msg = {
                sprintf('Image Browser %s', app.AppVersion)
                ''
                'A modern rewrite of the GUIDE-era imagebrowser for viewing'
                'series of images, defining regions of interest and plotting'
                'signal against slice, volume or an arbitrary x-axis.'
                ''
                sprintf('Running on MATLAB %s', version('-release'))
                };
            uialert(app.UI.Fig, msg, 'About', 'Icon', 'info');
        end
    end

    methods (Static, Hidden)
        function tf = isTextEntry(obj)
            %ISTEXTENTRY  True for controls that consume keystrokes themselves.
            tf = false;
            if isempty(obj), return; end
            try
                if ~isvalid(obj), return; end
            catch
                return
            end
            tf = isa(obj, 'matlab.ui.control.Table') || ...
                 isa(obj, 'matlab.ui.control.EditField') || ...
                 isa(obj, 'matlab.ui.control.NumericEditField') || ...
                 isa(obj, 'matlab.ui.control.TextArea') || ...
                 isa(obj, 'matlab.ui.control.Spinner') || ...
                 isa(obj, 'matlab.ui.control.DropDown') || ...
                 isa(obj, 'matlab.ui.control.ListBox');
        end

        function idx = toIndexed(img, lim, n)
            if size(img, 3) > 1
                img = mean(double(img), 3);
            end
            v = (double(img) - lim(1)) / max(eps, lim(2) - lim(1));
            v(~isfinite(v)) = 0;
            idx = uint8(min(n - 1, max(0, round(v * (n - 1)))));
        end

        function result = read2dseq(fileName, aSize, precision)
            %READ2DSEQ  Minimal reader for headerless Bruker 2dseq files.
            if nargin < 3 || isempty(precision), precision = 'uint16'; end
            bytesPerPix = ImageBrowserApp.bytesPerPixel(precision);
            s = dir(fileName);
            if isempty(s)
                error('ImageBrowser:fileNotFound', 'File not found: %s', fileName);
            end
            need = prod(aSize) * bytesPerPix;
            if need > s.bytes
                error('ImageBrowser:tooSmall', ...
                    'File holds %d bytes but %d are needed for the given size and precision.', ...
                    s.bytes, need);
            elseif need < s.bytes
                warning('ImageBrowser:tooLarge', ...
                    'File holds %d bytes but only %d are used.', s.bytes, need);
            end
            fid = fopen(fileName, 'r');
            c = onCleanup(@() fclose(fid));
            result = fread(fid, prod(aSize), ['*' precision]);
            result = reshape(result, aSize);
            result = permute(result, [2 1 3:numel(aSize)]);
        end

        function b = bytesPerPixel(precision)
            p = lower(char(precision));
            map = {'8',1; '16',2; '32',4; '64',8; 'double',8; 'single',4; ...
                'char',1; 'short',2; 'long',8; 'float',4; 'int',4};
            b = [];
            for k = 1:size(map, 1)
                if contains(p, map{k,1})
                    b = map{k,2};
                    break
                end
            end
            if isempty(b)
                error('ImageBrowser:badPrecision', 'Unrecognised binary precision "%s".', precision);
            end
        end
    end

    %======================================================================
    % Self test
    %======================================================================
    methods (Static, Hidden)
        function results = selftest(verbose)
            %SELFTEST  Exercise the browser without user interaction.
            %   ImageBrowserApp.selftest() constructs several browsers, drives
            %   navigation, ROIs, plotting, overlay and export, then closes
            %   them again.  It returns a table of test names and outcomes and,
            %   unless called with false, prints a PASS/FAIL line per test.
            if nargin < 1, verbose = true; end

            names = strings(0,1); ok = false(0,1); msg = strings(0,1);
            apps = {};
            a = [];  b = [];  c = [];  d = [];  %#ok<NASGU>

            rng(0);
            vol4 = single(abs(randn(48, 52, 6, 9)) * 100);
            vol4(3, 4, 1, 1) = NaN;
            im2 = magic(64);
            cellIn = {magic(32), rand(32), rand(32, 32, 4)};
            structIn = struct('anat', rand(24, 28), 'map', rand(24, 28, 3));

            record("construct 4-D numeric",            @tConstruct4D);
            record("navigable dimensions detected",    @tNavDims);
            record("frame count",                      @tFrameCount);
            record("goto frame",                       @tGotoFrame);
            record("step frame wraps",                 @tStepWrap);
            record("current image and NaN transparency", @tImage);
            record("colour limits minmax/robust/manual", @tCLim);
            record("colormap and colorbar",            @tCmap);
            record("montage build and hit test",       @tMontage);
            record("cine start and stop",              @tCine);
            record("mask outline geometry",            @tOutline);
            record("add ROI, statistics and table",    @tROI);
            record("copy ROI across frames",           @tCopy);
            record("ROI sequence export layout",       @tSeq);
            record("import legacy ROI formats",        @tImport);
            record("pixel and ROI curves",             @tPlot);
            record("overlay",                          @tOverlay);
            record("delete removes the selected ROI",  @tDeleteSelected);
            record("names and colours restart",        @tNamingRestarts);
            record("curve colours follow the ROIs",    @tCurveColours);
            record("fit target follows the dropdown",  @tFitTarget);
            record("Show governs plot and fit target", @tShowGoverns);
            record("first ROI switches to ROI mean",   @tRoiModeDefault);
            record("rename redraws the ROI label",     @tRenameRedraws);
            record("fit is named in the legend",       @tFitLegend);
            record("ROI names take the ROI colour",    @tNameColours);
            record("colours survive a middle delete",  @tColoursAfterDelete);
            record("controls keep their own keystrokes", @tKeyGuard);
            record("the ROI table is not rebuilt idly", @tTableStable);
            record("dirty flag tracks exports",        @tDirtyFlag);
            record("add and remove series",            @tSeries);
            record("theme switching",                  @tTheme);
            record("construct from cell array",        @tCell);
            record("construct from struct",            @tStruct);
            record("construct with no data (splash)",  @tSplash);
            record("2dseq reader round trip",          @t2dseq);
            record("colormap name list is usable",     @tNames);
            record("DKI Jacobian vs finite differences", @tJacDKI);
            record("DTI Jacobian vs finite differences", @tJacDTI);
            record("DKI recovers known parameters",    @tFitDKI);
            record("DTI recovers known parameters",    @tFitDTI);
            record("DTI is the K=0 special case",      @tFitConsistency);
            record("log-linear stage alone",           @tFitLogLinear);
            record("fit rejects too few points",       @tFitGuards);
            record("fit tolerates noise",              @tFitNoise);

            for k = 1:numel(apps)
                try
                    apps{k}.Closing = true;
                    apps{k}.stopCine();
                    delete(apps{k}.UI.Fig);
                catch
                end
            end

            results = table(names, ok, msg, 'VariableNames', {'Test', 'Passed', 'Message'});
            if verbose
                fprintf('\n%d of %d tests passed.\n', sum(ok), numel(ok));
            end

            % --- helpers ---------------------------------------------------
            function record(nm, fcn)
                names(end+1, 1) = nm;
                try
                    fcn();
                    ok(end+1, 1) = true;
                    msg(end+1, 1) = "";
                catch err
                    ok(end+1, 1) = false;
                    where = "";
                    for s = 1:min(4, numel(err.stack))
                        where = where + " <- " + string(err.stack(s).name) + ...
                            ":" + err.stack(s).line;
                    end
                    msg(end+1, 1) = string(err.identifier) + " " + ...
                        string(err.message) + where;
                end
                if verbose
                    if ok(end), verdict = 'PASS'; else, verdict = 'FAIL'; end
                    fprintf('%-44s %s\n', names(end), verdict);
                    if ~ok(end)
                        fprintf('      %s\n', msg(end));
                    end
                end
            end

            function want(cond, m)
                if ~cond
                    error('ImageBrowser:selftest', '%s', m);
                end
            end

            % --- tests -----------------------------------------------------
            function tConstruct4D()
                a = ImageBrowserApp(vol4, 'Name', 'selftest 4D', ...
                    'DimNames', ["slice" "b"], 'XData', 0:8, 'XLabel', "b");
                apps{end+1} = a;
            end

            function tNavDims()
                want(isequal(a.Series(1).NavSize, [6 9]), 'NavSize is wrong');
                want(a.Series(1).DimNames(2) == "b", 'DimNames were not applied');
            end

            function tFrameCount()
                want(a.frameCount() == 54, 'frameCount is wrong');
            end

            function tGotoFrame()
                a.gotoFrame(20);
                want(a.Frame == 20, 'the frame did not move');
                want(isequal(a.Sub, ImageBrowserApp.linear2sub([6 9], 20)), 'Sub is wrong');
            end

            function tStepWrap()
                a.gotoFrame(1);
                a.stepFrame(-1);
                want(all(a.Sub >= 1), 'wrapping produced an invalid subscript');
                a.gotoFrame(1);
            end

            function tImage()
                img = a.currentImage();
                want(isequal(size(img), [48 52]), 'the image size is wrong');
                a.gotoFrame(1);
                a.refreshImage();
                want(~isscalar(a.UI.Image.AlphaData), 'the NaN pixel was not made transparent');
            end

            function tCLim()
                a.setCLimMode("minmax");  l1 = a.CLim;
                a.setCLimMode("robust");  l2 = a.CLim;
                want(l2(1) >= l1(1) - eps && l2(2) <= l1(2) + eps, ...
                    'the robust limits are not inside the full range');
                a.CLim = [10 20];
                want(isequal(a.CLim, [10 20]), 'manual limits were not applied');
                a.adjustWL(0, 10);
                want(diff(a.CLim) < 10, 'raising the contrast did not narrow the window');
                a.setCLimMode("minmax");
            end

            function tCmap()
                a.Colormap = "gray";
                want(size(colormap(a.UI.Axes), 2) == 3, 'the colormap was not applied');
                a.setInvert(true); a.setInvert(false);
                a.setColorbar(true);
                want(logical(a.UI.CBar.Visible), 'the colorbar did not appear');
                a.setColorbar(false);
            end

            function tMontage()
                a.setMontage(true);
                want(isstruct(a.MontageMap), 'the montage map is missing');
                f = a.montageFrameAt(1, 1);
                want(f == a.MontageMap.Frames(1), 'the montage hit test is wrong');
                a.setMontage(false);
            end

            function tCine()
                a.setCine(true);
                want(~isempty(a.CineTimer), 'the cine timer was not created');
                pause(0.15);
                a.setCine(false);
                want(isempty(a.CineTimer), 'the cine timer was not cleared');
            end

            function tOutline()
                m = false(5, 5); m(2:3, 2:4) = true;
                [X, Y] = ImageBrowserApp.maskOutline(m);
                want(numel(X) == numel(Y), 'the outline vectors differ in length');
                g = isfinite(X);
                want(min(X(g)) == 1.5 && max(X(g)) == 4.5, 'the outline x range is wrong');
                want(min(Y(g)) == 1.5 && max(Y(g)) == 3.5, 'the outline y range is wrong');
            end

            function tROI()
                a.gotoFrame(5);
                m = false(48, 52); m(10:20, 10:20) = true;
                a.addROIRecord(m, [], "mask", "test1", [1 0 0]);
                a.refreshAll();
                want(numel(a.ROIs) == 1, 'the ROI was not stored');
                T = a.roiStats();
                want(height(T) == 1 && T.Npix == 121, 'the ROI statistics are wrong');
                u = a.getROIMask(true);
                want(any(u(:)), 'the union mask is empty');
                want(~isempty(a.OutlineH) || ~isempty(a.LiveROIs), 'the ROI was not drawn');
            end

            function tCopy()
                r = a.ROIs(1);
                for f = 1:5
                    r2 = r; r2.Frame = f;
                    a.ROIs(end+1) = r2;
                end
                want(numel(a.ROIs) == 6, 'the ROI copies were not stored');
            end

            function tSeq()
                seq = a.buildROISeq();
                want(iscell(seq.ROIs) && iscell(seq.Names), 'the ROIseq layout is wrong');
                want(numel(seq.ROIs) == a.frameCount(), 'the ROIseq length is wrong');
                want(islogical(seq.ROIs{5}), 'the ROIseq masks are not logical');
                L = a.legacyROIStats();
                want(isstruct(L) && isfield(L, 'Means'), 'the legacy stats layout is wrong');
            end

            function tImport()
                n0 = numel(a.ROIs);
                m = false(48, 52); m(30:35, 30:35) = true;
                a.importROIData(m, "imported2d");
                want(numel(a.ROIs) == n0 + 1, 'the 2-D mask import failed');
                seq = a.buildROISeq();
                n1 = numel(a.ROIs);
                a.importROIData(seq, "roundtrip");
                want(numel(a.ROIs) > n1, 'the ROI sequence import failed');
            end

            function tPlot()
                a.setPlotPanel(true);
                a.LastPixel = [12 12];
                a.setPlotMode("pixel");
                a.setSweepDim(2);
                [x, y] = a.sweepCurve();
                want(numel(x) == 9 && numel(y) == 9, 'the pixel curve has the wrong length');
                want(isequal(x, 0:8), 'the custom x-axis was not used');
                want(numel(a.UI.PlotLine.XData) == 9, 'the pixel line was not drawn');
                a.setPlotMode("roi");
                [x2, y2, sd2] = a.sweepCurve();
                want(numel(x2) == 9 && all(isfinite(y2)) && all(isfinite(sd2)), ...
                    'the ROI curve is incomplete');
                a.refreshPlot();
                want(numel(a.RoiLines) == numel(a.roisOnCurrentFrame()), ...
                    'one curve per ROI was not drawn');
                a.setPlotPanel(false);
            end

            function tDeleteSelected()
                a.gotoFrame(9);
                a.deleteFrameROIs();
                m1 = false(48,52); m1(5:10,  5:10)  = true;
                m2 = false(48,52); m2(20:25, 20:25) = true;
                m3 = false(48,52); m3(30:35, 30:35) = true;
                a.addROIRecord(m1, [], "mask", "first",  [1 0 0]);
                a.addROIRecord(m2, [], "mask", "second", [0 1 0]);
                a.addROIRecord(m3, [], "mask", "third",  [0 0 1]);
                a.refreshAll();
                want(numel(a.roisOnCurrentFrame()) == 3, 'three ROIs expected');

                here = a.roisOnCurrentFrame();
                a.UI.ROITable.Selection = 2;          % the middle one
                want(isequal(a.selectedROIIndices(), here(2)), ...
                    'the live selection does not map to the middle ROI');
                a.deleteSelectedROIs();
                left = a.roisOnCurrentFrame();
                nmLeft = strings(1, numel(left));
                for q = 1:numel(left)
                    nmLeft(q) = a.ROIs(left(q)).Name;
                end
                want(numel(left) == 2, 'exactly one ROI should have gone');
                want(all(nmLeft ~= "second"), 'the selected ROI was not the one deleted');
                want(any(nmLeft == "third"), 'the last ROI was deleted instead');

                a.UI.ROITable.Selection = 1;
                a.deleteSelectedROIs();
                want(numel(a.roisOnCurrentFrame()) == 1, 'deleting a single selection failed');
            end

            function tNamingRestarts()
                a.gotoFrame(11);
                a.deleteFrameROIs();
                m = false(48,52); m(5:9, 5:9) = true;
                a.addROIRecord(m, [], "mask", a.nextROIName(), a.nextColor());
                a.refreshAll();
                want(a.ROIs(end).Name == "roi1", 'first ROI on a clean frame should be roi1');
                c1 = a.nextColor();
                a.addROIRecord(m, [], "mask", a.nextROIName(), c1);
                a.refreshAll();
                want(a.ROIs(end).Name == "roi2", 'second ROI should be roi2');
                want(~isequal(a.ROIs(end).Color, a.ROIs(end-1).Color), ...
                    'two ROIs on one frame must not share a colour');
                a.deleteFrameROIs();
                a.addROIRecord(m, [], "mask", a.nextROIName(), a.nextColor());
                a.refreshAll();
                want(a.ROIs(end).Name == "roi1", 'naming did not restart after deleting all');
                a.deleteFrameROIs();
            end

            function tCurveColours()
                a.gotoFrame(13);
                a.deleteFrameROIs();
                m1 = false(48,52); m1(5:10,  5:10)  = true;
                m2 = false(48,52); m2(20:25, 20:25) = true;
                a.addROIRecord(m1, [], "mask", "aa", [1 0 0]);
                a.addROIRecord(m2, [], "mask", "bb", [0 1 0]);
                a.setPlotMode("roi");
                a.setPlotPanel(true);
                a.refreshAll();
                want(numel(a.RoiLines) == 2, 'expected one line per ROI');
                cols = vertcat(a.RoiLines.Color);
                want(ismember([1 0 0], cols, 'rows') && ismember([0 1 0], cols, 'rows'), ...
                    'curves are not drawn in the ROI colours');
                a.setPlotPanel(false);
            end

            function tFitTarget()
                a.gotoFrame(13);          % still holds aa and bb from above
                a.refreshAll();
                want(numel(a.UI.FitROIDrop.ItemsData) == 2, ...
                    'both shown regions should be offered as fit targets');
                a.UI.FitROIDrop.Value = a.UI.FitROIDrop.ItemsData(2);
                [x, y, ~, lbl, col] = a.sweepCurve();
                want(~isempty(x) && any(isfinite(y)), 'the chosen region gave no curve');
                want(isequal(col, [0 1 0]), 'the fit target is not the chosen region');
                want(contains(lbl, "bb"), 'the label should name the chosen region');

                % The table selection must not influence the fit target.
                a.UI.ROITable.Selection = 1;
                [~, ~, ~, ~, col2] = a.sweepCurve();
                want(isequal(col2, [0 1 0]), ...
                    'selecting a row must not change what gets fitted');
                a.UI.ROITable.Selection = [];
            end

            function tShowGoverns()
                a.gotoFrame(13);
                shown = a.shownROIsOnFrame();
                want(numel(shown) == 2, 'both regions should start shown');
                a.setPlotPanel(true); a.refreshAll();
                want(numel(a.RoiLines) == 2, 'both regions should be plotted');

                a.ROIs(shown(2)).Visible = false;
                a.refreshAll();
                want(numel(a.shownROIsOnFrame()) == 1, 'the hidden region is still shown');
                want(numel(a.UI.FitROIDrop.ItemsData) == 1, ...
                    'the hidden region is still offered as a fit target');
                want(numel(a.RoiLines) == 1, 'the hidden region is still plotted');
                a.setPlotPanel(false);
                a.deleteFrameROIs();
            end

            function tRoiModeDefault()
                a.gotoFrame(17);
                a.deleteFrameROIs();
                a.setPlotMode("pixel");
                m = false(48,52); m(5:9, 5:9) = true;
                a.addROIRecord(m, [], "mask", "d1", [1 0 0]);
                want(a.PlotMode == "roi", ...
                    'the first region on a frame should switch the plot to ROI mean');
                a.setPlotMode("pixel");     % a deliberate move back
                a.addROIRecord(m, [], "mask", "d2", [0 1 0]);
                want(a.PlotMode == "pixel", ...
                    'a later region must not override the chosen mode');
                a.deleteFrameROIs();
            end

            function tDirtyFlag()
                a.gotoFrame(15);
                a.deleteFrameROIs();
                m = false(48,52); m(5:9, 5:9) = true;
                a.addROIRecord(m, [], "mask", "x", [1 0 0]);
                want(a.ROIsDirty, 'adding a ROI should mark the set dirty');
                a.ROIsDirty = false;
                a.deleteFrameROIs();
                want(a.ROIsDirty, 'deleting should mark the set dirty');
                a.ROIsDirty = false;
            end

            function tRenameRedraws()
                a.gotoFrame(19);
                a.deleteFrameROIs();
                m = false(48,52); m(6:14, 6:14) = true;
                a.addROIRecord(m, [], "mask", "before", [1 0 0]);
                a.refreshAll();
                k = a.roisOnCurrentFrame();
                a.onROITableEdit(struct('Indices', [1 2], 'NewData', 'after'));
                want(a.ROIs(k(1)).Name == "after", 'the rename did not reach the record');
                want(any(cellfun(@(h) isvalid(h) && string(h.Label) == "after", ...
                    a.LiveROIs)) || isempty(a.LiveROIs), ...
                    'the label drawn on the image still shows the old name');
                a.deleteFrameROIs();
            end

            function tFitLegend()
                a.gotoFrame(21);
                a.deleteFrameROIs();
                m = false(48,52); m(6:14, 6:14) = true;
                a.addROIRecord(m, [], "mask", "wm", [1 0 0]);
                a.setPlotMode("roi");
                a.setPlotPanel(true);
                a.refreshAll();
                a.UI.FitModelDrop.Value = 'DKI';
                a.uiFitDiffusion();
                want(isfield(a.FitResult, 'Region') && a.FitResult.Region == "wm", ...
                    'the fit should record which region it describes');
                nm = string(a.UI.PlotFit.DisplayName);
                want(contains(nm, "wm"), 'the fitted curve is not named after the region');
                want(contains(nm, "DKI"), 'the fitted curve does not name the model');
                a.setPlotPanel(false);
                a.deleteFrameROIs();
            end

            function tNameColours()
                a.gotoFrame(23);
                a.deleteFrameROIs();
                m1 = false(48,52); m1(5:10,  5:10)  = true;
                m2 = false(48,52); m2(20:25, 20:25) = true;
                a.addROIRecord(m1, [], "mask", "red",    [1 0 0]);
                a.addROIRecord(m2, [], "mask", "yellow", [0.929 0.694 0.125]);
                a.refreshAll();
                sc = a.UI.ROITable.StyleConfigurations;
                want(height(sc) == 2, 'one style per region name was expected');
                want(isequal(a.legibleColor([1 0 0]), [1 0 0]), ...
                    'a colour that already reads well should be left alone');
                y = a.legibleColor([0.929 0.694 0.125]);
                want(all(y <= [0.929 0.694 0.125] + 1e-12) && any(y < 0.929), ...
                    'a pale colour should be darkened for a light table');
                want(abs(y(1)/y(2) - 0.929/0.694) < 1e-6, 'the hue should be preserved');
                a.deleteFrameROIs();
            end

            function tColoursAfterDelete()
                a.gotoFrame(25);
                a.deleteFrameROIs();
                m = false(48,52); m(5:9, 5:9) = true;
                for q = 1:5
                    a.addROIRecord(m, [], "mask", a.nextROIName(), a.nextColor());
                    a.refreshAll();
                end
                here = a.roisOnCurrentFrame();
                cols = vertcat(a.ROIs(here).Color);
                want(size(unique(cols, 'rows'), 1) == 5, ...
                    'five regions should have five distinct colours');

                a.ROIs(here(3)) = [];        % remove one from the middle
                a.refreshAll();
                a.addROIRecord(m, [], "mask", a.nextROIName(), a.nextColor());
                a.refreshAll();
                here = a.roisOnCurrentFrame();
                cols = vertcat(a.ROIs(here).Color);
                want(size(unique(cols, 'rows'), 1) == numel(here), ...
                    'a colour was reused after deleting a region from the middle');

                nm = strings(1, numel(here));
                for q = 1:numel(here)
                    nm(q) = a.ROIs(here(q)).Name;
                end
                want(numel(unique(nm)) == numel(nm), 'a name was reused as well');
                a.deleteFrameROIs();
            end

            function tKeyGuard()
                f = uifigure('Visible', 'off');
                cu = onCleanup(@() delete(f)); %#ok<NASGU>
                want(ImageBrowserApp.isTextEntry(uieditfield(f)), ...
                    'an edit field must keep its own keystrokes');
                want(ImageBrowserApp.isTextEntry(uitable(f)), ...
                    'a table must keep its own keystrokes');
                want(ImageBrowserApp.isTextEntry(uispinner(f)), ...
                    'a spinner must keep its own keystrokes');
                want(~ImageBrowserApp.isTextEntry(uibutton(f)), ...
                    'a button should not swallow the shortcuts');
                want(~ImageBrowserApp.isTextEntry([]), ...
                    'no focused object means the shortcuts apply');
            end

            function tTableStable()
                a.gotoFrame(27);
                a.deleteFrameROIs();
                m = false(48,52); m(5:9, 5:9) = true;
                a.addROIRecord(m, [], "mask", "stable", [1 0 0]);
                a.refreshAll();
                before = a.UI.ROITable.Data;
                a.refreshROITable();
                want(isequaln(before, a.UI.ROITable.Data), ...
                    'an idle refresh changed the table contents');
                a.ROIs(a.roisOnCurrentFrame()).Name = "moved";
                a.refreshROITable();
                want(~isequaln(before, a.UI.ROITable.Data), ...
                    'a real change was not picked up');
                a.deleteFrameROIs();
            end

            function tOverlay()
                a.setOverlay(rand(48, 52), 'Alpha', 0.4, 'Colormap', "hot");
                a.refreshImage();
                want(logical(a.UI.OverlayImage.Visible), 'the overlay is not shown');
                a.setActiveLayer("overlay");
                a.setCLim([0.2 0.8]);
                want(isequal(a.Overlay.CLim, [0.2 0.8]), 'the overlay limits were not applied');
                a.setActiveLayer("base");
                a.setOverlayEnabled(false);
            end

            function tSeries()
                a.addSeries(im2, "magic");
                want(a.seriesCount() == 2, 'the series was not added');
                a.selectSeries(2);
                want(isequal(size(a.currentImage()), [64 64]), 'switching series failed');
                a.removeSeries(2);
                want(a.seriesCount() == 1, 'the series was not removed');
                a.selectSeries(1);
            end

            function tTheme()
                a.setTheme("dark"); a.setTheme("light"); a.setTheme("system");
            end

            function tCell()
                b = ImageBrowserApp(cellIn, 'Name', 'selftest cell');
                apps{end+1} = b;
                want(b.seriesCount() == 3, 'the cell input gave the wrong series count');
                want(b.frameCount(3) == 4, 'the third series should have 4 frames');
            end

            function tStruct()
                c = ImageBrowserApp(structIn, 'Name', 'selftest struct');
                apps{end+1} = c;
                want(c.seriesCount() == 2, 'the struct input gave the wrong series count');
                want(c.Series(1).Name == "anat", 'the struct field name was lost');
            end

            function tSplash()
                d = ImageBrowserApp();
                apps{end+1} = d;
                want(d.seriesCount() == 1, 'the splash series is missing');
                want(d.Series(1).IsRGB, 'the splash image should be RGB');
            end

            function t2dseq()
                f = [tempname '_2dseq'];
                orig = int16(reshape(1:(8 * 6 * 3), [8 6 3]));
                fid = fopen(f, 'w');
                fwrite(fid, orig, 'int16');
                fclose(fid);
                back = ImageBrowserApp.read2dseq(f, [8 6 3], 'int16');
                delete(f);
                want(isequal(back, permute(orig, [2 1 3])), 'the 2dseq round trip failed');
            end

            function tNames()
                nm = ImageBrowserApp.colormapNames();
                want(~isempty(nm), 'no colormaps were found');
                for k = 1:numel(nm)
                    want(size(ImageBrowserApp.resolveColormap(nm(k), 16), 2) == 3, ...
                        char("colormap " + nm(k) + " failed"));
                end
            end

            % --- diffusion fitting -----------------------------------------
            function e = jacError(p, bb, mdl)
                % Complex-step differentiation. The model is exp of a
                % polynomial and therefore analytic, so Im f(x+ih)/h is exact
                % to machine precision: no truncation term and no subtractive
                % cancellation, unlike a finite difference. That matters here
                % because D is of order 1e-3 while b reaches 3e3, so the third
                % derivative that sets the central-difference error carries a
                % factor b^3 ~ 1e10.
                h = 1e-20;
                [~, Ja] = ImageBrowserApp.dkiSignal(p, bb, mdl);
                Jc = zeros(numel(bb), numel(p));
                for q = 1:numel(p)
                    pp = complex(p);
                    pp(q) = pp(q) + 1i * h;
                    Jc(:,q) = imag(ImageBrowserApp.dkiSignal(pp, bb, mdl)) / h;
                end
                scale = max(abs(Jc), [], 1);
                scale(scale == 0) = 1;
                e = max(abs(Ja - Jc) ./ scale, [], 'all');
            end

            function tJacDKI()
                bb = [0 100 300 600 1000 1500 2000 2500 3000];
                e = jacError([1200, 0.8e-3, 1.1], bb, "DKI");
                want(e < 1e-12, sprintf('DKI Jacobian error %.3g is too large', e));
                e = jacError([50, 3e-3, -0.4], bb, "DKI");   % negative K, fast D
                want(e < 1e-12, sprintf('DKI Jacobian error %.3g at second point', e));
            end

            function tJacDTI()
                bb = [0 100 300 600 1000 2000 3000];
                e = jacError([950, 1.2e-3], bb, "DTI");
                want(e < 1e-12, sprintf('DTI Jacobian error %.3g is too large', e));
            end

            function tFitDKI()
                bb = [0 100 300 600 1000 1500 2000 2500 3000];
                pTrue = [1200, 0.8e-3, 1.1];
                Sy = ImageBrowserApp.dkiSignal(pTrue, bb, "DKI")';
                r = ImageBrowserApp.fitDiffusion(bb, Sy, "DKI", true, true);
                want(max(abs(r.P - pTrue) ./ pTrue) < 1e-4, ...
                    sprintf('DKI recovered [%.4g %.4g %.4g]', r.P));
                want(r.R2 > 1 - 1e-10, 'DKI R2 should be essentially 1 on exact data');
            end

            function tFitDTI()
                bb = [0 100 300 600 1000];
                pTrue = [950, 1.2e-3];
                Sy = ImageBrowserApp.dkiSignal(pTrue, bb, "DTI")';
                r = ImageBrowserApp.fitDiffusion(bb, Sy, "DTI", true, true);
                want(max(abs(r.P - pTrue) ./ pTrue) < 1e-4, ...
                    sprintf('DTI recovered [%.4g %.4g]', r.P));
                want(r.K == 0, 'DTI must report K = 0');
            end

            function tFitConsistency()
                % A DKI fit to data generated with K = 0 must return K ~ 0 and
                % the same S0 and D as the two-parameter DTI fit.
                bb = [0 200 400 700 1000 1400];
                pTrue = [800, 0.9e-3];
                Sy = ImageBrowserApp.dkiSignal(pTrue, bb, "DTI")';
                rk = ImageBrowserApp.fitDiffusion(bb, Sy, "DKI", true, true);
                rd = ImageBrowserApp.fitDiffusion(bb, Sy, "DTI", true, true);
                want(abs(rk.K) < 1e-4, sprintf('K should vanish, got %.3g', rk.K));
                want(abs(rk.D - rd.D) / rd.D < 1e-4, 'D disagrees between DKI and DTI');
            end

            function tFitLogLinear()
                % With refinement off the result must still be the exact
                % log-linear solution on noiseless data.
                bb = [0 100 300 600 1000 1500 2000];
                pTrue = [1000, 0.7e-3, 0.8];
                Sy = ImageBrowserApp.dkiSignal(pTrue, bb, "DKI")';
                r = ImageBrowserApp.fitDiffusion(bb, Sy, "DKI", true, false);
                want(~r.Refined, 'Refined flag should be false');
                want(all(isnan(r.SE)), 'no standard errors without refinement');
                want(max(abs(r.P - pTrue) ./ pTrue) < 1e-6, ...
                    sprintf('log-linear recovered [%.4g %.4g %.4g]', r.P));
            end

            function tFitGuards()
                threw = false;
                try
                    ImageBrowserApp.fitDiffusion([0 100], [100 50], "DKI", true, true);
                catch
                    threw = true;
                end
                want(threw, 'DKI with 2 points should have been rejected');
                threw = false;
                try
                    ImageBrowserApp.fitDiffusion([0 100 300], [1 1 1], "ADC", true, true);
                catch
                    threw = true;
                end
                want(threw, 'an unknown model name should have been rejected');
            end

            function tFitNoise()
                rng(7);
                bb = [0 100 250 500 750 1000 1500 2000 2500 3000];
                pTrue = [1000, 0.85e-3, 1.0];
                Sy = ImageBrowserApp.dkiSignal(pTrue, bb, "DKI")' + 2 * randn(1, numel(bb));
                r = ImageBrowserApp.fitDiffusion(bb, Sy, "DKI", true, true);
                want(abs(r.D - pTrue(2)) / pTrue(2) < 0.10, ...
                    sprintf('D off by more than 10%%: %.4g', r.D));
                want(abs(r.K - pTrue(3)) < 0.25, ...
                    sprintf('K off by more than 0.25: %.4g', r.K));
                want(all(isfinite(r.SE)), 'standard errors should be finite');
            end
        end
    end

    %======================================================================
    % Pointer and keyboard interaction
    %======================================================================
    methods (Access = private)

        function [inside, x, y] = axesPoint(app)
            ax = app.UI.Axes;
            cp = ax.CurrentPoint;
            x = cp(1,1); y = cp(1,2);
            inside = x >= ax.XLim(1) && x <= ax.XLim(2) && ...
                y >= ax.YLim(1) && y <= ax.YLim(2);
        end

        function onMouseMove(app)
            if app.Closing || app.seriesCount() == 0, return; end
            [inside, x, y] = app.axesPoint();

            if app.WLDrag.Active
                app.doWLDrag(x, y);
                return
            end

            if ~inside
                app.UI.Fig.Pointer = 'arrow';
                return
            end
            app.UI.Fig.Pointer = 'crosshair';

            if app.MontageOn
                app.refreshStatus();
                return
            end

            img = app.currentImage();
            r = round(y); c = round(x);
            if r >= 1 && c >= 1 && r <= size(img,1) && c <= size(img,2)
                app.LastPixel = [r c];
                app.refreshStatus();
                if app.PixelSurf && app.PlotMode == "pixel"
                    app.refreshPlot();
                end
            end
        end

        function onMouseDown(app, ~)
            if app.Closing || app.seriesCount() == 0, return; end
            [inside, x, y] = app.axesPoint();
            if ~inside, return; end
            sel = app.UI.Fig.SelectionType;

            if strcmp(sel, 'alt')          % right button: window/level
                app.WLDrag.Active = true;
                app.WLDrag.Origin = [x y];
                app.WLDrag.CLim = app.activeCLim();
                app.UI.Fig.Pointer = 'fleur';
                return
            end

            if app.MontageOn
                f = app.montageFrameAt(x, y);
                if ~isempty(f)
                    app.setMontage(false);
                    app.gotoFrame(f);
                end
                return
            end

            img = app.currentImage();
            r = round(y); c = round(x);
            if r >= 1 && c >= 1 && r <= size(img,1) && c <= size(img,2)
                app.LastPixel = [r c];
                app.refreshStatus();
                app.refreshPlot();
            end
        end

        function onMouseUp(app)
            if app.WLDrag.Active
                app.WLDrag.Active = false;
                app.UI.Fig.Pointer = 'crosshair';
            end
        end

        function doWLDrag(app, x, y)
            ax = app.UI.Axes;
            w = diff(ax.XLim); h = diff(ax.YLim);
            if w <= 0 || h <= 0, return; end
            dx = (x - app.WLDrag.Origin(1)) / w;      % level
            dy = (y - app.WLDrag.Origin(2)) / h;      % width
            lim = app.WLDrag.CLim;
            span = lim(2) - lim(1);
            centre = mean(lim) + dx * span;
            newSpan = max(span * 1e-3, span * exp(dy * 2));
            app.CLimMode = "manual";
            app.UI.CLimModeDrop.Value = 'manual';
            app.setCLim(centre + [-0.5 0.5] * newSpan);
        end

        function f = montageFrameAt(app, x, y)
            f = [];
            m = app.MontageMap;
            if isempty(m) || ~isstruct(m), return; end
            ci = floor((x - 0.5) / m.W);
            ri = floor((y - 0.5) / m.H);
            if ci < 0 || ri < 0 || ci >= m.Cols || ri >= m.Rows, return; end
            t = ri * m.Cols + ci + 1;
            if t >= 1 && t <= numel(m.Frames)
                f = m.Frames(t);
            end
        end

        function onScroll(app, e)
            if app.Closing || app.seriesCount() == 0, return; end
            [inside, x, y] = app.axesPoint();
            if ~inside, return; end
            n = e.VerticalScrollCount;
            if app.ModCtrl || app.hasModifier('control')
                app.zoomAbout(x, y, 1.15 ^ n);
            else
                app.stepFrame(sign(n));
            end
        end

        function tf = hasModifier(app, name)
            tf = false;
            try
                tf = any(strcmp(app.UI.Fig.CurrentModifier, name));
            catch
                % CurrentModifier is not available on every release.
            end
        end

        function zoomAbout(app, x, y, factor)
            ax = app.UI.Axes;
            xl = ax.XLim; yl = ax.YLim;
            xl = x + (xl - x) * factor;
            yl = y + (yl - y) * factor;
            sz = size(app.UI.Image.CData);
            xl = [max(0.5, xl(1)), min(sz(2) + 0.5, xl(2))];
            yl = [max(0.5, yl(1)), min(sz(1) + 0.5, yl(2))];
            if diff(xl) > 1 && diff(yl) > 1
                ax.XLim = xl;
                ax.YLim = yl;
            end
        end

        function tf = typingInControl(app)
            %TYPINGINCONTROL  Does a control currently own the keyboard?
            tf = false;
            try
                tf = ImageBrowserApp.isTextEntry(app.UI.Fig.CurrentObject);
            catch
                % CurrentObject is unavailable on some releases; assume not.
            end
        end

        function onKey(app, e)
            app.ModCtrl = any(strcmp(e.Modifier, 'control'));
            if app.typingInControl()
                % A table cell, edit field, spinner, dropdown or list has
                % focus. Its own keys must reach it: an arrow key while
                % renaming a region used to change frame, and rebuilding the
                % table under the open editor left the cell stuck.
                return
            end
            switch lower(e.Key)
                case 'rightarrow', app.stepFrame(1);
                case 'leftarrow',  app.stepFrame(-1);
                case 'pagedown',   app.stepFrame(10);
                case 'pageup',     app.stepFrame(-10);
                case 'home',       app.gotoFrame(1);
                case 'end',        app.gotoFrame(app.frameCount());
                case 'uparrow',    app.selectSeries(app.SeriesIndex - 1);
                case 'downarrow',  app.selectSeries(app.SeriesIndex + 1);
                case 'space'
                    if isempty(app.CineTimer), app.startCine(); else, app.stopCine(); end
                case 'c', app.toggleColorbar();
                case 'l', app.toggleCLimLock();
                case 'r', app.resetCLim();
                case 'm', app.toggleMontage();
                case {'add', 'equal', 'hyphen'}
                    app.adjustWL(0, 10);
                case {'subtract', 'minus'}
                    app.adjustWL(0, -10);
                case 'escape'
                    app.stopCine();
            end
        end

        %------------------------------------------------------------------
        function onClose(app)
            if ~isempty(app.ROIs) && app.ROIsDirty
                choice = uiconfirm(app.UI.Fig, ...
                    sprintf(['%d region(s) of interest have not been exported ' ...
                    'since they were last changed. Save them to the base ' ...
                    'workspace before closing?'], numel(app.ROIs)), ...
                    'Close Image Browser', ...
                    'Options', {'Save and close', 'Close without saving', 'Cancel'}, ...
                    'DefaultOption', 1, 'CancelOption', 3);
                switch choice
                    case 'Save and close'
                        if ~app.uiExportROISeq()
                            return   % name dialog cancelled: do not lose the ROIs
                        end
                    case 'Cancel'
                        return
                end
            end
            app.Closing = true;
            app.stopCine();
            app.clearLiveROIs();
            delete(app.UI.Fig);
        end
    end
end
