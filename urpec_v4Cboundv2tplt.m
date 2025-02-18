function [fieldsFileName] = urpec_v4Cboundv2tplt( config )
% Testing with contour fracture function
% urpec_v4 Generates a proximity-effect-corrected pattern file for EBL
%
% function [  ] = urpec_v4( config )
% To run urpec and make a run file, see the script run_urpec.
% 
% The corrected file is created by deconvolving a point spread function 
% from an input .dxf or .mat pattern file.
% 
% The output file has different colors, each of which recieve a different
% dose. This function assumes that one unit in the input pattern file is one
% micron.
%
% The layer scheme is as follows. The names for all layers should be numbers.
% Layers 1 and 2 of the input file will
% both be output to layer 1 of the output file. Layer 1 will not be
% fractured, and layer 2 will be fractured. Layers 3 and 4 of the input
% file will be output to layer 2 of the output filed, etc. If the polygons
% are not fractured, the are written with an average dose. 
%
% urpec_v4 removes all duplicate vertices in the polygons. 
%
% config is an optional struct with the following optional fields:
%
%   dx: spacing in units of microns for the deconvolution. The default is
%   0.01 mcirons. It is also best to have the step size several times
%   larger than the center-center or line-line spacing in npgs. 
%
%   maxIter: maximum number of iterations for the deconvolution. Default is
%   6.
%
%   dvals: doses corresponding to the layers in the output file. Default is
%   1, 1.1, 2.0 in units of the dose to clear.
%   
%   targetPoints: approximate number of points for the simulation. Default
%   is 50e6.
%
%   autoRes: enables auto adjustment of the resolution for ~10min
%   computation time
%
%   file: datafile for processing. This can either be a .dxf file or a .mat
%   file. If it is a .mat file, the contets of the file should be a struct
%   called polygons. The polygons struct should have at least these fields:
%       p: a cell array of polygons. Each element of the cell array should
%       be a nx2 array of coordinates describing the poylgon.
%       layer: an array of numbers specifying the layer of each polygon
%       according to the convention described above.
%
%   psfFile: point-spread function file
%
%   fracNum: maximum number of times to divide each polygon during every
%   fracturing iteration.
%
%   fracSize: minimum size for fractured shapes, in units of dx.
%
%   padLen: the size with which to pad the CAD file, in units of microns.
%   The defaul is 5 microns. In general, a larger pad size will improve the
%   accuracy by accounting for long-distance proximity effects, but the
%   computation will take longer.
%
%   outputDir: the directory in which to save the output files.
%
%   savedxf: boolean variable indicating whether or not to save output dxf.
%   Default is false, although autocad is a nice way to view complex files.
%
%   savedc2: boolean variable indicating whether or not to save output dc2.
%   Default is false. If you are using NPGS, set this to true.
%
%   savedose: boolean variable indicating whether or not to save a text file with doses. 
%   Default is false. If you are using NPGS, set this to true.
%
%   npgs: boolean variable indicating whether or not you intend to use
%   NPGS. Default is false. If true, savedc2 and savedose will be set to
%   true.
%
%   overlap: boolean variable indicating how overlaps are handled. If false,
%   urpec will accont for the fact that overlap areas are multiply exposed.
%   If true, urpec will allow over exposure in overlap regions. Default is
%   true.
%
%   triangulate: boolean variable indicating whether or not to triangulate
%   non-convex polygons. Enabling this generates lots of triangles, but all of
%   the polygons will be good, and the fracturing is faster. Default is true.
%
% call this function without any arguments, or via
% urpec(struct('dx',0.005, 'subfieldSize',20,'maxIter',6,'dvals',[1:.2:2.4]))
% for example
%
%
% By:
% Adina Ripin 
% Elliot Connors econnors@ur.rochester.edu
% John Nichol jnich10@ur.rochester.edu
%
% Version history
% v2: handles different write fields and writes directly to dc2 format.
% v3: 
%   writes all doses to the same layer but with different colors. 
%   PSF improvements
%   Entirely new fracturing algorithm
% v4: 
%   Code refactoring: new functions shrinkArray and fracturePoly
%   Major speedups in the exposure map creation by using poly2mask
%   Improved fracturing algorithm that will triangulate if needed.

debug=0;

tic

orig_state=warning;
warning('off');

fprintf('urpec is running.\n');

if ~exist('config','var')
    config=struct();
end

config = def(config,'dx',.01);   %Grid spacing in microns. This is can be affected by config.targetPoints and config.autores
config = def(config,'targetPoints',50e6);  %Target number of points for the simulation. 
config = def(config,'autoRes',true);  %auto adjust the resolution
config = def(config,'maxIter',6);  %max number of iterations for the deconvolution
config = def(config,'dvals',linspace(1,2.0,15));  %doses corresponding to output layers, in units of dose to clear
config=def(config,'file',[]); 
config=def(config,'psfFile',[]);
config=def(config,'fracNum',4); %Must be >2, otherwise DIVIDEXY has problems.
config=def(config,'fracSize',2);
config=def(config,'padLen',5);
config=def(config,'savedxf',false);
config=def(config,'savedc2',false);
config=def(config,'savedose',false);
config=def(config,'npgs',false);
config=def(config,'overlap',true);
config=def(config,'triangulate',false);

if config.npgs
    config.savedose=true;
    config.savedc2=true;
    config.dvals=linspace(config.dvals(1),config.dvals(end),15); %make sure we have 15 colors.
end

%For NPGS: 15 dose values. These jet-like colors are compatible with NPGS
ctab={[0 0 175] [0 0 255] [0 63 255] [0 127 255] [0 191 255] [15 255 239] [79 255 175] [143 255 111] [207 255 047] [255 223 0] [255 159 0] [255 095 0] [255 31 0] [207 0 0] [143 0 0] };

%For other dose configurations, make a jet-like color map.
ncolors=length(config.dvals);
cc=jet(256);
dc=256/ncolors;
if ncolors~=15
    ctab={};
    for ic=1:ncolors
        ctab{ic}=round([cc((ic-1).*dc+1,:)].*255);
    end
end

% ########## Find pattern file ##########
%config.file = '2D.dxf';
%config.psfFile = 'PSFGaAs30kV200.mat';
if isempty(config.file)
    %choose and load file
    fprintf('Select your cad file.\n')
    [filename, pathname]=uigetfile({'*.dxf';'*.mat'});
    [pathname,filename,ext] = fileparts(fullfile(pathname,filename));
else
    [pathname,filename,ext] = fileparts(config.file);
    
end

pathname=[pathname '\'];
filename=[filename ext];

config=def(config,'outputDir',pathname);
if config.outputDir(end)~='\'
    config.outputDir=[config.outputDir '\'];
end

% ########## Load pattern from .dxf ##########
if strmatch(ext,'.dxf')
    [lwpolylines,lwpolylayers]=dxf2coord_20(pathname,filename);
    %These are actually the layer names, not the numbers. 
    %If they do not follow the convention, then default to layer 2 and
    %fracturing.
    for i=1:length(lwpolylayers)
        if isempty(str2num(lwpolylayers{i}))
            lwpolylayers{i}='2';
        end
    end
    layerNum=str2num(cell2mat(lwpolylayers));
    
    %splitting each set of points into its own object
    object_num=max(lwpolylines(:,1)); % number of polygons in CAD file
    objects = cell(1,object_num); % cell array of polygons in CAD file
    len = size(lwpolylines,1); % total number of polylines

    % populating 'objects' (cell array of polygons in CAD file)
    count = 1;
    obj_num_ind_start = 1;
    for obj = 1:len % loop over each polyline
        c = lwpolylines(obj,1); % c = object number
        if c ~= count
            objects{count} = lwpolylines(obj_num_ind_start:(obj-1), 1:3); %ID, x, y
            obj_num_ind_start = obj;
            count = count + 1;
            if count == object_num
                objects{count} = lwpolylines(obj_num_ind_start:(len), 1:3);
            end
        end

    end
    if object_num <= 1
        objects{count} = lwpolylines(:, 1:3);
    end
    
    %If something went wrong with the extraction, default to fracturing
    %everything into layer 1.
    if length(layerNum)~=length(objects)
        layerNum=ones(1,length(objects)).*2;
    end
    
    %Make a polygons struct
    polygons=struct();
    for io=1:length(objects)
        polygons(io).layer=layerNum(io);
        
        p=objects{io}(:,2:3);
       
        polygons(io).p=p;
    end
end

% ########## Load pattern from .mat ##########
if strmatch(ext,'.mat')
    d=load([pathname filename]);     
    if isfield(d,'polygons')
        polygons=d.polygons;
        [polygons.dose]=deal(1); %if there is no dose assigned, set it to 1. 
    elseif isfield(d,'fields')
        polygons=d.fields.polygons;
    else
        polygons=struct();
    end
end
fprintf('CAD file imported.\n');

xv=[];
yv=[];

% ########## Analyze polygons ##########

%Find the approximate size of the polygons and try to clean them up. 
%This does not handle duplicate vertices well. 
progressbar('Analyzing polygons');
for ip=1:length(polygons)
    progressbar(ip/length(polygons));
    x=polygons(ip).p(:,1);
    y=polygons(ip).p(:,2);
    [x1,y1]=fixPoly(x,y);
    polygons(ip).p=[x1 y1];

    sx=max(polygons(ip).p(:,1))-min(polygons(ip).p(:,1));
    sy=max(polygons(ip).p(:,2))-min(polygons(ip).p(:,2));
    polygons(ip).polysize=min([sx,sy]);
    xv=[xv; polygons(ip).p(:,1)];
    yv=[yv; polygons(ip).p(:,2)];
end

%Check for convexity and triangulate non-convex polygons if needed
polygonsTmp=struct();

for fn = fieldnames(polygons)'
   polygonsTmp.(fn{1}) = [];
end

nc=0; %counter for number of non-convex polygons
for ip = 1:length(polygons)
       
    p=polygons(ip).p; %p(:,2:3);
    
    fracture=~mod(polygons(ip).layer,2);

    isConvex = checkConvex(p(:,1)',p(:,2)');
    if ~isConvex && fracture 
        %fprintf('Non-convex polygon to be fractured found. \n');
        nc=nc+1;
        x=p(:,1)';
        y=p(:,2)';
        
        if config.triangulate
            %polyin=polyshape(x,y);
            %fracture it into triangles
            parent=struct();
            parent.x=x;
            parent.y=y;
    
            T=triangulatePoly(parent);
            T=checkPolys(T,parent);
            T=fixPolys(T);
            T=checkPolys(T,parent);
    
            for tt=1:length(T)
                polygonsTmp(end+1)=polygons(ip);
                polygonsTmp(end).p=[T{tt}.x(:) T{tt}.y(:)]; %convert to column vectors.
            end
        else
            polygonsTmp(end+1)=polygons(ip);
        end
        
    else
        polygonsTmp(end+1)=polygons(ip);
    end
            
end
fprintf('Found %d non-convex polygons to be fractured. \n',nc);

polygons=polygonsTmp;
polygons=polygons(2:end); %We initialized it with an empty element.

% ########## Creating exposure map ##########

maxX = max(xv);
maxY = max(yv);
minX = min(xv);
minY = min(yv);

dx = config.dx;

fprintf(['Creating 2D binary grid spanning all polygons (spacing = ', num2str(dx), ').\n']);

%Make the simulation area bigger by 5 microns to account for proximity effects
maxXold=maxX;
minXold=minX;
maxYold=maxY;
minYold=minY;
padSize=ceil(5/dx).*dx;
padPoints=padSize/dx;
maxX=maxXold+padSize;
minX=minXold-padSize;
maxY=maxYold+padSize;
minY=minYold-padSize;

xpold = minXold:dx:maxXold;
ypold = minYold:dx:maxYold;

xp = minX:dx:maxX;
yp = minY:dx:maxY;

%Check to make sure we aren't going to use all the memory.
totPoints=length(xp)*length(yp);
fprintf('There are %2.0e points. \n',totPoints);

%Make sure the grid size is appropriate
if config.autoRes && (totPoints<.8*config.targetPoints || totPoints>1.2*config.targetPoints)
    %The following way of changing the resolution will yield a step size
    %that is a power of 2 different that the originally specified step
    %size.
    expand=ceil(log2(sqrt(totPoints/config.targetPoints)));
    dx=dx*2^(expand);

    %This way of changing the resolution will get as close as possible to
    %the target.
%     expand=sqrt(totPoints/config.targetPoints);
%     dx=dx*(expand);
%     dx=round(dx,3);
%     if dx==0
%         dx=0.001;
%     end

    config.dx=dx; %very important for fracturing.
    fprintf('Resetting the resolution to %3.4f.\n',dx);
    padSize=ceil(5/dx).*dx;
    padPoints=padSize/dx;
    maxX=maxXold+padSize;
    minX=minXold-padSize;
    maxY=maxYold+padSize;
    minY=minYold-padSize;
    xp = minX:dx:maxX;
    yp = minY:dx:maxY;
    xpold = minXold:dx:maxXold;
    ypold = minYold:dx:maxYold;
    
    fprintf('There are now %2.0e points.\n',length(xp)*length(yp));
end

xp = minX:dx:maxX;
%%%xl = [minX maxX];
yp = minY:dx:maxY;
%%%yl = [minY maxY];
%Make sure the number of points is odd. This is important for deconvolving
%the psf
addX=0;
if ~mod(length(xp),2)
    addX=1;
    xp=[xp xp(end)+dx];
end

addY=0;
if ~mod(length(yp),2)
    addY=1;
    yp=[yp yp(end)+dx];
end

[XP, YP] = meshgrid(xp, yp);

[mp, np] = size(XP);

totgridpts = length(xp)*length(yp);

%polysbin is a 2d array that is zero except inside the polygons
polysbin = zeros(size(XP));

progressbar(sprintf('Creating the exposure pattern for %d polygons.',length(polygons)))
for ip=1:length(polygons)
    progressbar(ip/length(polygons));    
    
    [xinds,yinds]=shrinkArray(xp,yp,polygons(ip).p);
    
    x=round((polygons(ip).p(:,1)-xp(xinds(1)))/dx);
    y=round((polygons(ip).p(:,2)-yp(yinds(1)))/dx);
    subpoly=poly2mask(x',y',length(yinds),length(xinds));
    polysbin(yinds,xinds)=polysbin(yinds,xinds)+subpoly;
    
end

[xpts ypts] = size(polysbin);

% ########## Load PSF ##########

if isempty(config.psfFile)
    fprintf('Select point spread function file.\n')
    load(uigetfile('*PSF*'));
else
    load(config.psfFile);
end

minSize=min([max(XP(:))-min(XP(:)),max(YP(:))-min(YP(:))]);
psfRange=round(min([minSize,20]));
%This will break if psfRange is smaller than dx.
npsf=round(psfRange./dx);
[xpsf ypsf]=meshgrid([-npsf:1:npsf],[-npsf:1:npsf]);
xpsf=xpsf.*dx;
ypsf=ypsf.*dx;
rpsf2=xpsf.^2+ypsf.^2;
rpsf=rpsf2.^(1/2);

if ~isfield(psf,'version')
    psf.version=1;
end

switch psf.version
    case 1 %legacy
        eta=psf.eta; %ratio of total back scattered energy to forward-scattered energy.
        alpha=psf.alpha; %alpha, forward scattering range
        beta=psf.beta; %beta, reverse scattering range
        descr=psf.descr;
        
        %compute the forward and backscattered parts separately to enforce
        %the proper ratios.
        psfForward=1/(1+eta).*(1/(pi*alpha^2).*exp(-rpsf2./alpha.^2));
        psfBackscatter=1/(1+eta).*(eta/(pi*beta^2).*exp(-rpsf2./beta.^2));
        
        psf=psfForward./sum(psfForward(:))+eta*psfBackscatter./sum(psfBackscatter(:));
        
    case 2 %version 2
        descr=psf.descr;
        params=psf.params;
        alpha=10^params(1)*1e-3; %alpha, forward scattering range
        beta=10^params(2)*1e-3; %beta, reverse scattering range
        gamma=10^params(3)*1e-3; %gamma, exponential tail range
        
        r=params(4); %ratio of total back scattered energy to forward-scattered energy.
        eta=r-params(5); %eta
        nu=params(5); %gamma
        
        %compute the forward and backscattered parts separately to enforce
        %the proper ratios.
        psfForward= 1/(pi*(1+eta+nu)).*((1/alpha^2).*exp(-(rpsf2)./(alpha^2)));
        psfBackscatter=1/(pi*(1+eta+nu)).*((eta/beta^2).*exp(-(rpsf2)./(beta^2))+(nu/(24*gamma^2)).*exp(-(rpsf./gamma).^(1/2)));
        psf=psfForward./sum(psfForward(:))+(eta+nu)*psfBackscatter./sum(psfBackscatter(:));      
end

%normalize
psf=psf./sum(psf(:));

%Zero pad to at least 10um x 10 um. This is needed in case the sample is
%very small.

%pad in the x direction
xpad=size(polysbin,1)-size(psf,1);
if xpad>0
    psf=padarray(psf,[xpad/2,0],0,'both');
    padPoints1=padPoints;
elseif xpad<0
    polysbin=padarray(polysbin,[-xpad/2,0],0,'both');
    padPoints1=padPoints-xpad/2;
end

padPoints1=round(padPoints1);

%pad in the y direction
ypad=size(polysbin,2)-size(psf,2);
if ypad>0
    psf=padarray(psf,[0,ypad/2],0,'both');
    padPoints2=padPoints;
elseif ypad<0
    polysbin=padarray(polysbin,[0,-ypad/2],0,'both');
    padPoints2=padPoints-ypad/2; 
end

padPoints2=round(padPoints2);

% ########## Deconvolution ##########

dstart=polysbin;
if config.overlap
    %1 inside shapes and 0 everywhere else. Allow overexposure.
    shape=polysbin>0;
else
    %Compensate for overlaps.
    shape=polysbin;
end

dose=dstart;
doseNew=shape; %Initial guess at dose. Just the dose to clear everywhere.
figure(555); clf; imagesc(xp,yp,polysbin);
set(gca,'YDir','norm');
title('CAD pattern');
drawnow;

%The deconvolution method is to convolve with the psf, add the difference
%between actual dose and desired dose to the programmed dose, and the
%repeat.
meanDose=0;
progressbar('Deconvolving');
for iter=1:config.maxIter
    progressbar(iter/config.maxIter);
    %convolve with the point spread function, 
    doseActual=ifft2(fft2(doseNew).*fft2(psf)); 

    doseActual=real(fftshift(doseActual)); 
    %The next line is needed becase we are trying to do FFT shift on an
    %array with an odd number of elements. 
    doseActual(2:end,2:end)=doseActual(1:end-1,1:end-1);
    doseShape=doseActual.*shape; %total only given to shapes. Excludes area outside shapes. We don't actually care about this.
    meanDose=nanmean(doseShape(:))./mean(shape(:));
    
    figure(556); clf;
    subplot(1,2,2);
    imagesc(xp,yp,doseActual);
    title(sprintf('Actual dose. Iteration %d',iter));
    set(gca,'YDir','norm');
    
    doseNew=doseNew+1.2*(shape-doseShape); %Deonvolution: add the difference between the desired dose and the actual dose to doseShape, defined above
    subplot(1,2,1);
    imagesc(xp,yp,doseNew);
    title(sprintf('Programmed dose. Iteration %d',iter));
    set(gca,'YDir','norm');
    
    drawnow;
    
end

if meanDose<.98
    warning('Deconvolution not converged. Consider increasing maxIter.');
end

dd=doseNew;
ss=shape;

%Unpad arrays
doseNew=dd(padPoints1+1:end-padPoints1-1*addY,padPoints2+1:end-padPoints2-1*addX);
shape=ss(padPoints1+1:end-padPoints1-1,padPoints2+1:end-padPoints2-1);
mp=size(doseNew,1);
np=size(doseNew,2);

%This is needed to not count the dose of places that get zero or NaN dose.
try
    doseNew(doseNew==0)=NaN;
    doseNew(doseNew<0)=NaN;
end
[N,X]=hist(doseNew(:),config.dvals);
figure(557); clf; subplot(2,1,1);
hist(doseNew(:),config.dvals);
xlim([0.8,2.5]);
xlabel('Relative dose');
ylabel('Fractured count');
subplot(2,1,2);
hist(doseNew(:),64);
xlim([0.8,2.5]);
xlabel('Relative dose');
ylabel('Pixel count');

drawnow;
if max(N)==N(end)
    warning('Max dose is the highest dval. Consider changing your dvals.');
end

doseStore=doseNew;

dvals=config.dvals;
nlayers=length(dvals);
dvalsl=dvals-(dvals(2)-dvals(1));
dvalsr=dvals;
layer=[];
figSize=ceil(sqrt(nlayers));
dvalsAct=[];
 
% ########## Fracturing ##########

subField=struct();
[XPold, YPold] = meshgrid(xpold, ypold);
nPolys2Frac=sum(~mod([polygons.layer],2));
nPolysNot2Frac=sum(mod([polygons.layer],2));
%progressbar(sprintf('Fracturing/Averaging %d/%d',nPolys2Frac,nPolysNot2Frac));
triCount=0;




dvals = config.dvals;
dDose = dvals(2)-dvals(1);
maxDose = max(doseNew(:));
minDose = min(doseNew(:));

% min to max (in to out) vector for easier polygon, hole assignment 
% each polygons becomes a hole for the next set of polygons because we are
% going from inside to out. Dose is incremented by the desired dose
% difference between polygons.
clvl = minDose:dDose:maxDose;

% colon operator may not return minDose 
% if non-integer increment is specificed
clvl(end) = maxDose; 

clen = length(clvl);




% Graphics array
%go = gobjects(0);

% strultimate is a structure within a structure within a structure
% First level holds the number of contours
% Within each contour is the number of objects (and the information needed
% to triangulate (Delaunay) once the holes are defined) 
% Within each of those objects are the holes (if present)
% These structures are mostly for debugging and plotting and could likely
% be taken out without any issue.
%
% each dose region is determined by the lower dose (specified in clvl)
% subtracted from the higher dose (the level above)
% doses of interest are assigned to 1 while everything else is set to zero
% 
% CL and PL are the connectivity list and points list of the triangulation
% object we produce while the profile and constraints are what we use to
% determine that triangulation
% It was easier to add everything to a single matrix and keep track of 
% connectivity than to create more structures than already present
% Triangulation is impossible on lines (zero area triangles) which is why
% this script checks for non-zero area and 
% at least three vertices before proceeding
% 
% The script checks to see if any holes are present before assigning them
% to the profile and the holes structure is redefined after every loop in
% case the value was saved but not overwritten
% Connectivity defined similarly to the isinterior documentation but it is
% generalized for any loops

strultimate(clen-1) = struct('boundsDT',struct('dose',[],'outerbounds',[], 'innerbounds', struct, 'CL', [], 'PL', [], 'totalprofile', [], 'constraints', []),'dose',[]);
striangle = struct([]);
for i=1:(clen - 1)
    k = i + 1;
    SMC = doseNew;
    SMCDose = SMC(SMC > clvl(i) & SMC < clvl(k));
    SMC(SMC > clvl(i) & SMC < clvl(k)) = 1;
    SMC(SMC ~= 1) = 0;
    [mv,ind]=min(abs(dvals-nanmean(SMCDose(:))));
    strultimate(i).dose = ind;
    [B,L,N,A] = bwboundaries(SMC);
    for u = 1:length(B)
        B{u} = unique(B{u},'rows');
    end
    for j = 1:N
        if polyarea((B{j}(:,1)),(B{j}(:,2))) == 0 || length(B{j}) < 3
            continue
        end
        strultimate(i).boundsDT(j).dose = ind;
        strultimate(i).boundsDT(j).outerbounds = B{j};
        ob = B{j}; % for plotting
        lcon = length(B{j}(:,1));
        profile = B{j};
        conecvec = [(1:lcon-1)' (2:lcon)'; lcon 1];
        ibloop = (nnz(A(:,j)));
        inbd2plot = struct('x',{},'y',{});
        if ibloop  > 0
            em = 1;
            inbd2plot(ibloop) = struct('x',[],'y',[]);
            inbdst(length(ibloop)) = struct('holes',[]);
            for l = find(A(:,j))'
                if polyarea((B{l}(:,1)),(B{l}(:,2))) == 0 || length(B{l}) < 3
                    continue
                end
                inbdst(em).holes = B{l};
                strultimate(i).boundsDT(j).innerbounds = inbdst;
                inbd2plot(em).x = B{l}(:,1);
                inbd2plot(em).y = B{l}(:,2);
                em = em + 1;
                profile = [profile; B{l}];
                lincon = length(B{l}(:,1));
                stind = sum(lcon) + 1;
                lcon = [lcon lincon];
                endind = sum(lcon);
                convaddit = [(stind:endind-1)' (stind+1:endind)'; endind stind];
                conecvec = [conecvec; convaddit];
            end
        end
        strultimate(i).boundsDT(j).totalprofile = profile;
        strultimate(i).boundsDT(j).constraints = conecvec;
        DT = delaunayTriangulation(profile,conecvec);
        IO = isInterior(DT);
        strultimate(i).boundsDT(j).PL = DT.Points;
        strultimate(i).boundsDT(j).CL = DT.ConnectivityList(IO,:);
        striangle(end + 1).dose = ind;
        striangle(end).PL = DT.Points;
        striangle(end).CL = DT.ConnectivityList(IO,:);
%         figure(7)
%         %axes(xlim = [minXold maxXold], ylim = [minYold maxYold]);
%         sp1 = subplot(2,2,1);
%         patch(ob(:,1),ob(:,2),'-k','EdgeColor','k','FaceColor','none','LineWidth',1);
%         hold on
%         if ~isempty(inbd2plot)
%             for b = 1:em-1
%                 patch(inbd2plot(b).x,inbd2plot(b).y,'-r','EdgeColor','r','FaceColor','none','FaceAlpha',.5);
%             end
%         end
%         hold off
%         sp2 = subplot(2,2,2);
%         triplot(DT);
%         sp3 = subplot(2,2,3);
%         triplot(DT);
%         hold on
%         patch(ob(:,1),ob(:,2),'-k','EdgeColor','k','FaceColor','none','LineWidth',1);
%         if ~isempty(inbd2plot)
%             for b = 1:em-1
%                 patch(inbd2plot(b).x,inbd2plot(b).y,'-r','EdgeColor','r','FaceColor','none','FaceAlpha',.5);
%             end
%         end
%         hold off
%         sp4 = subplot(2,2,4);
%         patch(ob(:,1),ob(:,2),'-k','EdgeColor','k','FaceColor','none','LineWidth',1);
%         hold on
%         if ~isempty(inbd2plot)
%             for b = 1:em-1
%                 patch(inbd2plot(b).x,inbd2plot(b).y,'-r','EdgeColor','r','FaceColor','none','FaceAlpha',.5);
%             end
%         end
%         triplot(DT(IO,:),DT.Points(:,1),DT.Points(:,2));
%         linkaxes([sp1,sp2,sp3,sp4])
%         hold off
%         %go(end + 1) = figure(7);
    end
end

%subplot 1 polygon and hole
%subplot 2 triangulation
%subplot 3 triangulation in polygon
%subplot 4 triangulation within boundaries
                



% final structure
subField2fix = struct('x',zeros(3,1),'y',zeros(3,1),'p',zeros(3,2),'dose',[],'layer',1);
subField = struct('x',zeros(3,1),'y',zeros(3,1),'p',zeros(3,2),'dose',[],'layer',1);
% go from triangle data to coordinates
% figure(3)
% xlim([minXold maxXold])
% ylim([minYold maxYold])
for tri = 1:length(striangle)
    CL = striangle(tri).CL;
    PL = striangle(tri).PL;
    dose = striangle(tri).dose;
    %triplot(CL,PL(:,1),PL(:,2),Color = ctab{dose}./255);
    %hold on
    for itri = 1:size(CL, 1)
        xnew = zeros(3,1);
        ynew = zeros(3,1);
        for cind = 1:3
            vcind = CL(itri,cind);
            xnew(cind) = PL(vcind,1);
            ynew(cind) = PL(vcind,2);
        end
%         subField2fix(end+1).x = xnew;
%         subField2fix(end).y = ynew;
%         subField2fix(end).dose = dose;
%         subField(end+1) = fixPoly2mod(subField2fix(end));
%         subField(end).dose = dose;
        subField(end+1).x = xnew;
        subField(end).y = ynew;
        subField(end).dose = dose;
    end
end
%hold off

dvalsAct=dvals;



% patch with fix poly2
% figure(41)
% xlim([minXold maxXold])
% ylim([minYold maxYold])
% for sf = 2:length(subField)
%     fill(subField(sf).x,subField(sf).y,ctab{subField(sf).dose}./255);
%     hold on
% end
% hold off
% ########## Exporting ##########

%save the final files
fields=struct();

outputFileName=[config.outputDir filename(1:end-4) '_' descr '.dxf'];

if config.savedxf
    fprintf('Exporting to %s\n',outputFileName);
    try
        FID = dxf_open(outputFileName);
    catch
        fprintf('Either dxf_open isn''t on your path, or you need to close the dxf file, and then type dbcont and press enter. \n')
        keyboard;
        FID = dxf_open(outputFileName);
    end
end
        
polygons=struct();
polygons(1)=[];

%Write in order of objects.
%figure(778); clf; hold on;
%the subfield struct array holds all of the fractured polygons which came
%from the initial polygons.
progressbar('Saving');


%%%%%% should change the indices first index is blank.
for ip=2:length(subField)
    progressbar(ip/length(subField));
    if ~isempty(subField(ip).x) %Needed because sometimes our fracturing algorithm generates empty polygons.
            i=subField(ip).dose;
            X=subField(ip).x; 
            Y=subField(ip).y;
            Z=X.*0;              
            if config.savedxf
                FID=dxf_set(FID,'Color',ctab{i}./255,'Layer',subField(ip).layer);
                dxf_polyline(FID,[X(:); X(1)],[Y(:); Y(1)],[Z(:); Z(1)]); %urpec has no duplicate vertices, but dxf files want the same starting and ending vertex.
            end            
            polygons(end+1).p=[X(:) Y(:)]; %Make sure we have column vectors at the end
            polygons(end).color=ctab{i}; 
            polygons(end).layer=subField(ip).layer;
            polygons(end).lineType=1;
            polygons(end).dose=subField(ip).dose;
    end 
end

if config.savedxf
    dxf_close(FID);
end

if config.savedc2
    fields.cadFile=[filename(1:end-4) '_' descr '.dc2']; %used by NPGS
    dc2FileName=[config.outputDir filename(1:end-4) '_' descr '.dc2'];
    fprintf('Exporting to %s\n',dc2FileName);
    dc2write(polygons,dc2FileName);
end

%Save doses here
if config.savedose
    fields.doseFile=[filename(1:end-4) '_' descr '.txt'];
    doseFileName=[config.outputDir filename(1:end-4) '_' descr '.txt'];
    fprintf('Exporting to %s\n',doseFileName);
    fileID = fopen(doseFileName,'w');
    fprintf(fileID,'%3.3f \r\n',dvalsAct);
    fclose(fileID);
end

%Save all of the information in a .mat file for later.
fields.dvalsAct=dvalsAct;
fields.polygons=polygons;
fields.ctab=ctab;
fieldsFileName=[config.outputDir filename(1:end-4) '_' descr '_fields.mat'];
fprintf('Exporting to %s\n',fieldsFileName);
try
    save(fieldsFileName,'fields');
catch
    fprintf('Can''t save the fields file. Change your path, and then type dbcont and press enter. \n')
    keyboard;
    save(fieldsFileName,'fields');
end
warning(orig_state);

fprintf('urpec is finished.\n')

toc

end

% Apply a default.
function s=def(s,f,v)
if(~isfield(s,f))
    s=setfield(s,f,v);
end
end

