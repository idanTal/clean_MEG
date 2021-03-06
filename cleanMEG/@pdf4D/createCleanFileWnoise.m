function ok = createCleanFileWnoise(pdf, inFile, varargin)
% Create a new pdf file from an old one
% ok = createCleanFile(pdf, inFile, , varargin);
%    e.g.
% >> fileNameNew = 'C:\DATA\MEG\Noise\28-Oct-2008\onBed\c_rfhp1.new';
% >> ok = createCleanFile(fileNameNew, [], 256, 'byFFT');
%
% pdf     - any pdf4D oblect - not truly used here
% inFile  - full path and name of the old file
%   VARARGIN allows for parameter pairs ('name',value) to be specified
%   Legal pairs are
% 'outFile' - full path and name of the new file, or
%           - [] when "automatic" file name is generated (this is the
%           default)
% 'byLF'    - text or a powerof 2 numeric value.
%      if a number: 0 do not clean the Line frequency artefacts
%           2^n the value of the trigger bit for line f marker (e.g. 256)
%      if text: 'byLF' will search for a bit which is time locked within 1
%           cycle either to 50 or 60 Hz. Other text means do not attemppt to
%           clean line frequency. (default 'byLF')
%           This will be applied to MEG and REF channels and if available also to
%           EEG and external channels, this bit will then be removed from
%           the trig channel.
% 'byFFT'    - 'None'   Do not use REF channels to clean the  MEG
%              'byFFT' If to clean also the MEG channels to obtain minimal
%                       power at all frequencies (default 'byFFT')
% 'RInclude' - 'All'       - means consider all REF channels
%            - 'Automatic' - means exclude channels with small dinamic
%                            range, (this is the default)
%            - array       - list of channel numbers to include
% 'RiLimit'  - value in [0,1], setting the dynamic range of REF to be
%              accepted.  (lower values mean be MORE selective). 
%              [default 0.85].
% 'HeteroCoefs' - to use previously prepared coeficients for cleaning
%              either []  - for computing coeficients with every piece
%              or coefStruct As obtained by coefsAllByFFT. (default [])
% 'DefOverflow' - define the value for overflow in MEG (default 1e-11).
% 'CleanPartOnly' - pair of times [T1,T2] in seconds. leave some parts 
%              as is and use only the part between T1 and T2.
%
%
% coefStruct   - structure with allCoefs, eigVec, bands, as follows:
%     allCoefs     - the coeficients for channel and each band in the frequency domain
%     eigVec       - eigen vectors of ref in columns (Only if ref is in time
%                    domain)  It is scaled up by rFactor.
%     bands        - the bands Used in Hz, inclusive bounderies

%
% NOTE this will work properly only if data in the file is continuous
% this is done by reading the source file in pieces, cleaning and writing
% back to the destination file.  It will work also for Windows.

% Nov-2008  MA
%  Updates
%  Dec-2008  Epoched data is cleaned from line frequency one epoch at a
%            time.  MA
%  Jan-2009  if 'byLF' the bit which locks to 50 (or 60) Hz is found
%            automatically.  MA
%  Jul-2009  VARARGIN added some variables added to it.
%            REF channels with low dynamic range are excluded (this happens
%            when DELTA encoding is used to collect the data)  MA
%            channels with large (>1e-11) values are not cleaned.  MA
%  Oct-2009 Allow to deal with only part of the data via <'CleanPartOnly',
%            [T1, T2]>.  MA

%% Initialize
ok = false;
if ispc % adjust this according to the max memory in the system
    samplesPerPiece = 160000;
else
    samplesPerPiece = 320000;
end
warning('ON', 'MEGanalysis:missingInput:settingBands')

%% test for VARARGIN
if nargin > 2
    if rem((nargin-2),2)~= 0
        error('MATLAB:MEGanalysis:WrongNumberArgs',...
            'Incorrect number of arguments to %s.',mfilename);
    end
    okargs = {'outFile', 'byLF', 'byFFT', 'RInclude', 'RiLimit','HeteroCoefs',...
        'DefOverflow', 'CleanPartOnly'};
    okargs = lower(okargs);
    for j=1:2:nargin-2
        pname = varargin{j};
        pval = varargin{j+1};
        k = strmatch(lower(pname), okargs);
        if isempty(k)
            error('MATLAB:MEGanalysis:BadParameter',...
                'Unknown parameter name:  %s.',pname);
        elseif length(k)>1
            error('MATLAB:MEGanalysis:BadParameter',...
                'Ambiguous parameter name:  %s.',pname);
        else
            switch(k)
                case 1  % outFile
                    outFile = pval;
                case 2  % byLF
                    byLF = pval;
                case 3 %  byFFT
                    byFFT = pval;
                case 4 %  RInclude
                    if ischar(pval)
                        RIval={'all','automatic'};
                        kk = strmatch(lower(pval), RIval);
                        if isempty(kk)
                            error('MATLAB:MEGanalysis:BadParameter',...
                                'Unknown parameter value:  %s.',pval);
                        elseif length(k)>1
                            error('MATLAB:MEGanalysis:BadParameter',...
                                'Ambiguous parameter value:  %s.',pval);
                        else
                            switch(k)
                                case 1  % None
                                    Rchans2Include = [];  % do not ignore any
                                    makeIgnoreList = false;
                                case 2  % Automatic
                                    makeIgnoreList = true;
                            end  % end of switch for RIval
                        end  % end of test for unique value
                    else  %A numeric list
                        Rchans2Include = pval;
                        makeIgnoreList = false;
                    end  % end of test for char values
                    case 5 %  RiLimit
                        RiLimit = pval;
                case 6 % 'HeteroCoefs'
                    coefStruct = pval;
                case 7 % 'DefOverflow'
                    overFlowTh = pval;
                case 8  % 'CleanPartOnly'
                    tStrt = pval(1);
                    tEnd  = pval(2);
                    aPieceOnly=true;
            end  % end of switch
        end  % end of tests for unique arg name
    end  % end of testing for even number of argumants
end  % end of more then two input arguments


%% define the missing variables
if ~exist('outFile','var'), outFile =[]; end
if ~exist('RiLimit','var'), RiLimit =[]; end
if isempty(RiLimit), RiLimit = 0.85; end 
if ~exist('overFlowTh', 'var'), overFlowTh=[]; end
if isempty(overFlowTh), overFlowTh= 1e-11; end
if ~exist('byFFT','var'), byFFT =[]; end
if isempty(byFFT) 
    doFFT = true;
else
    doFFT = strcmpi(byFFT, 'byFFT'); 
end
if ~exist('byLF','var'), byLF =[]; end
if isempty(byLF)
    doLineF = true; 
    findLF = true;
elseif ischar(byLF)
    if strcmpi(byLF, 'byLF');
        findLF = true;
        doLineF = true;
    elseif strcmpi(byLF, 'None')
        findLF = false;
        doLineF = false;
    else
        error('MATLAB:MEGanalysis:improperParameterValue',...
            'Values for ''byLF'' are: number, ''byLF'' or ''None''')
    end
else % not a char - assume a number
    doLineF = true;
    lineF = byLF;
    findLF = false;
end
if ~exist('makeIgnoreList','var'), makeIgnoreList =true; end
if ~exist('coefStruct','var'), coefStruct=[]; end
if isempty(coefStruct)
    externalCoeficients = false;
else
    externalCoeficients = true;
end
if ~exist('aPieceOnly','var'), aPieceOnly=false; end
if ~exist('tStrt','var'), tStrt=[]; end
if isempty(tStrt), tStrt=0; end
pIn=pdf4D(inFile);
samplingRate   = double(get(pIn,'dr'));
hdr = get(pIn, 'header');
lastSample = double(hdr.epoch_data{1}.pts_in_epoch);
if ~exist('tEnd','var'), tEnd=[]; end
if isempty(tEnd), tEnd=lastSample/samplingRate; end
numEpochs = length(hdr.epoch_data);
if numEpochs>1 && tStrt>0
    % error('MATLAB:pdf4D:notContinuous','Cannot clean epoched files')
    error ('MATLAB:pdf4D:notContinuous',...
        'Cleaning only part of data doesnot work on epoched recordings')
end

%% read a piece of the trig signal to find if Line frequency is available
if findLF
    chit = channel_index(pIn,'TRIGGER');
    trig = read_data_block(pIn,double(samplingRate*[1,5]),chit);
    if isempty(trig)
        warning('MATLAB:MEGanalysis:noData','Line Frequency trig not found')
        doLineF = false;
    else
        lineF = findLFbit(trig,samplingRate);
        if isempty(lineF)
            warning('MATLAB:MEGanalysis:noData','Line Frequency trig not found')
            doLineF = false;
        else
            doLineF = true;
        end
    end
end

%% find which REF channels to ignore
chirf = channel_index(pIn,'ref');
if makeIgnoreList
    %  algorithm
    % for each channel:
    %    make a histogram of REF values with 256 bins
    %    find the 10% to 90% values
    %    if the fraction of bins with 0 counts there is < RiLimit accept
    %    this channel.
    testT=20;
    if lastSample/samplingRate<20
        testT = lastSample/samplingRate;
    end
    REF = read_data_block(pIn,double(samplingRate*[1,testT]),chirf);
    % search for channels with low dinamic range
    fN=zeros(1,length(chirf));
    ilst = 1:length(chirf);
    for jj = 1:length(ilst)
        ii = ilst(jj);
        hst=hist(diff(REF(ii,:)),256);
        chst = cumsum(hst);
        lo=find(chst>0.1*chst(end),1);
        hi=find(chst>0.9*chst(end),1);
        if lo==hi
            f=1;
        else
            f = sum(hst(lo:hi)==0)/(hi-lo);
        end
        fN(jj)=f;
    end
    Rchans2Include = find(fN<=RiLimit);
    if length(Rchans2Include)<9
        sFN = sort(fN);
        newRL = sFN(9);
        Rchans2Include = find(fN<=newRL);
        warning('MATLAB:MEGanalysis:notEnoughInputs', ...
            ['Not enogh REF channels with enough dynamic range!' ...'
            '\n changing threshold to %d'],newRL)
        % doFFT=false;
    end
end

%% continue checkups
if ~doLineF && ~doFFT
    warning('MATLAB:MEGanalysis:notEnoughInputs', 'Nothing to clean - ABORTING!')
    return
end
if isempty(outFile)
    if doLineF, outFile = [inFile ',lp'];
    else outFile=inFile; end
    if doFFT, outFile = [outFile ',cf']; end
end
if exist(outFile, 'file')
    R = input(['outFile ' outFile ' already exists.  Do you wish to replace? [''y''/''n''] ']);
    if R(1)~='y' &&  R(1)~='Y'
        disp('Aborting')
        return
    end
end
if ispc
    command = ['copy "' inFile '" "' outFile '"'];
    disp(['Wait while : ' command])
    [s,w]=dos(command);
    if s~=0  % error
        error('MEGanalysis:fileNames',['could not copy files: ' w])
    end
elseif isunix
    command = ['cp ' inFile ' ' outFile];
    unix(command);
else
    warning('MEGanalysis:unknownSystem','Unsupported operating system - nothing done')
    return
end
%% start the file and get parameters
p=pdf4D(outFile);
% cnf = p.config;
hdr = get(p,'header');
%empty header means no pdf
if isempty(hdr)
    error('MATLAB:MEGanalysis:noPDFfile','Need pdf to write data')
end

numEpochs = length(hdr.epoch_data);
if numEpochs>1
    % error('MATLAB:pdf4D:notContinuous','Cannot clean epoched files')
    warning ('MATLAB:pdf4D:notContinuous','epoched data, data "stitched" at bounderies')
    epoched = true;
    epochStart= nan(1,numEpochs);
    lastSample=0;
    for ii=1:numEpochs
        epochStart(ii) = lastSample+1;
        lastSample = lastSample+double(hdr.epoch_data{ii}.pts_in_epoch);
    end
    epochEnds = [epochStart(2:end)-1, lastSample];
else
    epoched = false;
    lastSample = double(hdr.epoch_data{1}.pts_in_epoch);
end
samplingRate   = double(get(p,'dr'));
chi = channel_index(p,'meg');
chn = channel_name(p,chi);
numMEGchans = length(chi);
[chnSorted, chiSorted] = sortMEGnames(chn,chi);
chix = channel_index(p,'EXTERNAL');
chit = channel_index(p,'TRIGGER');
% chir = channel_index(p,'RESPONSE');
if ~isempty(chix)
    chnx = channel_name(p,chix);
    [chnxSorted, chixSorted] = sortMEGnames(chnx,chix);
end
chie = channel_index(p,'EEG');
if ~isempty(chie)
    che = channel_name(p,chie);
    [cheSorted, chieSorted] = sortMEGnames(che,chie);
end
chirf = channel_index(p,'ref');
if ~isempty(Rchans2Include)
    chirf = chirf(Rchans2Include);
end

%% readjust the bounderies
if samplesPerPiece>lastSample
    samplesPerPiece= round(lastSample/2);
end
if ~epoched
    if  ~aPieceOnly
        numPieces = ceil(lastSample/samplesPerPiece);
        samplesPerPiece= floor(lastSample/numPieces);
        startApiece = 1:samplesPerPiece:lastSample;
        stopApiece  = startApiece+samplesPerPiece;
        deltaEnd = lastSample-stopApiece(end);
        if deltaEnd<0
            stopApiece(end) = lastSample;
        else
            error ('wrong division of data')
        end
    else
        numSamples = round((tEnd-tStrt)*samplingRate);
        numPieces = ceil(numSamples/samplesPerPiece);
        samplesPerPiece= floor(numSamples/numPieces);
        firstS = floor(tStrt*samplingRate);
        lastSample = firstS + numSamples-1;
        startApiece = firstS:samplesPerPiece:lastSample;
        stopApiece  = startApiece+samplesPerPiece;
        deltaEnd = lastSample-stopApiece(end);
        if deltaEnd<0
            stopApiece(end) = lastSample;
        else
            error ('wrong division of data')
        end
    end
else  % cut on epoch bounderies
    startApiece=nan(1,numEpochs);
    stopApiece = startApiece;
    ii=1;
    i0=1;
    while i0<lastSample
        startApiece(ii)=epochStart(i0);
        ie=find((epochEnds(i0:end)-startApiece(ii))...
            >samplesPerPiece,1)+i0-1;
        if ie>i0
            stopApiece(ii)=epochEnds(ie-1);
        else
            stopApiece(ii)=lastSample;
        end
        ii = ii+1;
        i0=ie;
    end
    startApiece(ii:end)=[];
    stopApiece(ii:end)=[];
    % if the last piece is very short - add to the one before last
    lastPiece = stopApiece(end)-startApiece(end);
    if lastPiece<0.1*samplesPerPiece
        startApiece(end)=[];
        stopApiece(end) = [];
        stopApiece(end)=lastSample;
        repeatDivision=false;
    elseif lastPiece<0.5*samplesPerPiece  % divide it amongst all others
        numPieces = size(stopApiece,2);
        samplesPerPiece = samplesPerPiece +ceil(lastPiece/numPieces);
        repeatDivision=true;
    else
        repeatDivision=false;
    end
    if repeatDivision  % do again the division
        ii=1;
        i0=1;
        while i0<lastSample
            startApiece(ii)=epochStart(i0);
            ie=find((epochEnds(i0:end)-startApiece(ii))...
                >samplesPerPiece,1)+i0-1;
            if ie>i0
                stopApiece(ii)=epochEnds(ie-1);
            else
                stopApiece(ii)=lastSample;
            end
            ii = ii+1;
            i0=ie;
        end
        startApiece(ii:end)=[];
        stopApiece(ii:end)=[];
        
    end % end of repeat division
    numPieces = length(startApiece);
end

%% decide on size of time slice to process
% find if a line frequency trigger exists
totalT = lastSample/samplingRate;
linePeriod = round(samplingRate/50);  % the default value
if doLineF
    if totalT>20
        trig = read_data_block(p,double(samplingRate*[0.1,20]),chit); 
    else
        trig = read_data_block(p,double(samplingRate*[0.1,totalT]),chit);
    end
    whereUp=find(diff(mod(trig,2*lineF-1)>=lineF)==1);
    if isempty(whereUp)
        doLineF=false;
        warning ('MEGanalysis:missingParam','Couldnot clean the line artefacts')
        linePeriod=10;
    else
        linePeriod = round(mean(diff(whereUp)));
    end
end
df=1/linePeriod;
transitionFactors = (0.5*df:df:1-0.5*df); % factors for merging near the cutoff between files
numTransition = length(transitionFactors);
transitionFactors = repmat(transitionFactors,numMEGchans,1);
if epoched
    MEGoffset = zeros(length(chiSorted),1);
%     MEGprevMean = zeros(length(chiSorted),1);
    if exist('chirf','var')
        if epoched
            REFoffset = zeros(length(chirf),1);
%             REFprevMean = zeros(length(chirf),1);
        end
    end
    if exist('chieSorted','var')
        if epoched
            EEGoffset = zeros(length(chieSorted),1);
%             EEGprevMean = zeros(length(chieSorted),1);
        end
    end
    if exist('chixSorted','var')
        if epoched
            XTRoffset = zeros(length(chixSorted),1);
%             XTRprevMean = zeros(length(chixSorted),1);
        end
    end    
end

%% prepare for reading and writing the file

%total number of channels in pdf
total_chans = double(hdr.header_data.total_chans);

%BTi Data Formats:
SHORT   =	1;
LONG    =	2;
FLOAT   =	3;
DOUBLE  =	4;


%open file (to read and write), always big endean
fid = fopen(outFile, 'r+', 'b');

if fid == -1
    error('Cannot open file %s', outFile);
end

%% clean the data
transitions=nan(1,numPieces);
for ii = 1:numPieces
    startI = startApiece(ii);
    endI  = stopApiece(ii);
    disp(['cleaning the piece ' num2str([startI,endI]/samplingRate)])
    if epoched
        startTime = find(epochEnds>startI,1);
        stopTime = find(epochEnds<endI,1,'last');
        timeListTmp = epochEnds(startTime:stopTime);
        timeList=[0, (timeListTmp -startI+1) 0];
    else
        timeList=[0,endI-startI+1];
    end
    trig = read_data_block(p, [startI,endI], chit);
    if doLineF
        whereUp=find(diff(mod(trig,2*lineF-1)>=lineF)==1);
    end
    transitions(ii) = endI;

    % read all types of data
    MEG = read_data_block(p, [startI,endI], chiSorted);
    % sometimes the last value is HUGE??
    [I,junkData] = find(MEG>1e-8,1);
    if ~isempty(junkData)
        endI = startI + size(MEG,2)-1;
        warning('MATLAB:MEGanalysis:nonValidData', ...
            ['MEGanalysis:overflow','Some MEG values are huge at: ',...
            num2str(endI/samplingRate) ' - truncated'])
        MEG(:,junkData:end)=[];
        timeList(end) = junkData-1;
    else
        timeList(end) = size(MEG,2);
    end
    
    if exist('chieSorted','var')
        EEG = read_data_block(p, [startI,endI], chieSorted);
    end
    if ~exist('chirf','var')
        chirf = channel_index(p,'ref');
    end
    if ~isempty(chirf)  % read the reference channels
        % chnrf = channel_name(p,chirf);
        REF = read_data_block(p, [startI,endI], chirf);
    end
    if exist('chixSorted','var')  % read the reference channels
        XTR = read_data_block(p, [startI,endI], chixSorted);
    end
    
%% stitch the transitions between epochs
%     if epoched  % stitch at epochs ends
%         firstEpoch = find(epochStart>=startI,1);
%         lastEpoch = find(epochEnds>=endI,1);
%         stitchS =epochStart(firstEpoch:lastEpoch) -startI +1;
%         stitchE =epochEnds(firstEpoch:lastEpoch) -startI +1;
%     else
%         firstEpoch=1;
%         lastEpoch = 1;
%         stitchS=1;
%         stitchE=size(MEG,2);
%     end
    if epoched
        [MEG, MEGoffset] = stitch(MEG, timeList,MEGoffset);
        if ~isempty(chirf)
            [REF, REFoffset] = stitch(REF, timeList,REFoffset);
        end
        if ~isempty(chie)
            [EEG, EEGoffset] = stitch(EEG, timeList,EEGoffset);
        end
        if ~isempty(chix)
            [XTR, XTRoffset] = stitch(XTR, timeList,XTRoffset);
        end
    end
%%    % clean the 50Hz if needed
    if doLineF
        if epoched
            MEG = cleanLineF(MEG, whereUp, timeList);
            REF = cleanLineF(REF, whereUp, timeList);
            if exist('chieSorted','var')  % clean the 50 Hz
                EEG = cleanLineF(EEG, whereUp, timeList);
            end
            if exist('chixSorted','var')  % clean the 50 Hz
                XTR = cleanLineF(XTR, whereUp, timeList);
            end
        else
            MEG = cleanLineF(MEG, whereUp);
            REF = cleanLineF(REF, whereUp);
            if exist('chieSorted','var')  % clean the 50 Hz
                EEG = cleanLineF(EEG, whereUp);
            end
            if exist('chixSorted','var')  % clean the 50 Hz
                XTR = cleanLineF(XTR, whereUp);
            end
        end
    end
    if doFFT
        if ~externalCoeficients
            sumOverflow = sum(sum(abs(MEG)>overFlowTh))>0;
            if ii==1  % test for overflow on first piece
                if ~sumOverflow
                    [MEG, coefStruct]  = coefsAllByFFT(MEG,REF,samplingRate,...
                        [],overFlowTh);
                else % cannot overcome the overflow problem
                    if ispc 
                        delete(outFile);
                    elseif isunix
                        command = ['rm' outFile];
                        unix(command);
                    else
                        disp(['Unknown system. Remove ' outFile ' manually!'])
                    end
                    error('MATLAB:MEGanalysis:cannotPerformFunction','cannot Clean. Cleaned file is removed.')
                end
            else  % ii>1 first section already cleaned, and auto-clean
                if ~sumOverflow
                    [MEG, coefStruct]  = coefsAllByFFT(MEG,REF,samplingRate,...
                        [], overFlowTh);
                else  % overflow & ii>1
                    [MEG, coefStruct]  = coefsAllByFFT(MEG,REF,samplingRate,...
                        coefStruct, overFlowTh);
                end
            end  % end for test if ii==1
        else  % use external coeficients
            [MEG, coefStruct]  = coefsAllByFFT(MEG,REF,samplingRate,...
                coefStruct, overFlowTh);
        end
        if ii>1  % make a smooth transition between the end of last piece
            % and the begining of the new one
            MEG(:,1:numTransition) = endOfPiece.*transitionFactors +...
                (1-transitionFactors).*MEG(:,1:numTransition);
        end
        % save the last samples for creating a smooth transition to the
        % next piece
        if ii<numPieces % truncate the last piece
            endOfPiece = MEG(:,end-numTransition+1:end);
            MEG(:,end-numTransition+1:end) = [];
            REF(:,end-numTransition+1:end) = [];
            trig(end-numTransition+1:end)=[];
            transitions(ii) = startI + size(MEG,2)-1;
            startApiece(ii+1) = transitions(ii)+1;  % Start next piece from 
            %                        the beginning of the overlapping piece
            if exist('chieSorted','var')  % EEG exists
                EEG(:,end-numTransition+1:end) = [];
            end
            if exist('chixSorted','var')  % XTR exists
                XTR(:,end-numTransition+1:end) = [];
            end
        end
    end

%% replace the old data by the cleaned data
    switch hdr.header_data.data_format
        case SHORT
            data_format = 'int16=>int16';
            data_format_out = 'int16';
            time_slice_size = 2 * total_chans;
            config = get(p, 'config');
            if isempty(config)
                error('No Config: Could not scale data\n');
            end
            scale = channel_scale(config, hdr, 1:total_chans);
            MEG = int16(MEG ./ repmat(scale(chiSorted)', 1, size(MEG,2)));
            REF = int16(REF ./ repmat(scale(chirf)', 1, size(REF,2)));
            if exist('chieSorted','var')  % EEG exists
                EEG = int16(EEG ./ repmat(scale(chie)', 1, size(EEG,2)));
            end
            if exist('chixSorted','var')  % XTR exists
                XTR = int16(XTR ./ repmat(scale(chix)', 1, size(XTR,2)));
            end
        case LONG
            data_format = 'int32=>int32';
            data_format_out = 'int32';
            time_slice_size = 4 * total_chans;
            config = get(p, 'config');
            if isempty(config)
                error('No Config: Could not scale data\n');
            end
            scale = channel_scale(config, hdr, 1:total_chans);
            MEG = int32(MEG ./ repmat(scale(chi)', 1, size(MEG,2)));
            REF = int32(REF ./ repmat(scale(chirf)', 1, size(REF,2)));
            if exist('chieSorted','var')  % EEG exists
                EEG = int32(EEG ./ repmat(scale(chie)', 1, size(EEG,2)));
            end
            if exist('chixSorted','var')  % XTR exists
                XTR = int32(XTR ./ repmat(scale(chix)', 1, size(XTR,2)));
            end
        case FLOAT
            data_format = 'float32=>float32';
            data_format_out = 'float32';
            time_slice_size = 4 * total_chans;
            MEG = single(MEG);
            REF = single(REF);
            if exist('chieSorted','var')  % EEG exists
                EEG = single(EEG);
            end
            if exist('chixSorted','var')  % XTR exists
                XTR = single(XTR);
            end
        case DOUBLE
            data_format = 'double';
            time_slice_size = 8 * total_chans;
            MEG = double(MEG);
            REF = double(REF);
            if exist('chieSorted','var')  % EEG exists
                EEG = double(EEG);
            end
            if exist('chixSorted','var')  % XTR exists
                XTR = double(XTR);
            end
        otherwise
            error('Wrong data format : %d\n', hdr.header_data.data_format);
    end
    %skip some time slices
    lat = startI;
    %     if lat>1  %  skip
    status = fseek(fid, time_slice_size * (lat-1), 'bof');
    if status~=0
        error('MEGanalysis:pdf:fileOperation', ['Did not advance the file ' ferror(fid)])
        fclose(fid)
    end
    %     end
    % Read the old data and replace with new
    oldData = fread(fid, [total_chans, size(MEG,2)], data_format);
    oldData(chiSorted,:) = MEG;  % replace the MEG channels
    oldData(chirf,:) = REF;  % replace the REF channels
    if exist('chieSorted','var')
        oldData(chieSorted,:) = EEG;  % replace the EEG channels
    end
    if exist('chixSorted','var')
        oldData(chixSorted,:) = XTR;  % replace the XTR channels
    end
    if doLineF
        trig = clearBits(trig, lineF);
        oldData(chit,:)=trig;
    end
    status = fseek(fid, time_slice_size * (lat-1), 'bof');
    if status~=0
        error('MEGanalysis:pdf:fileOperation', ['Did not advance the file ' ferror(fid)])
        fclose(fid)
    end

    fwrite(fid, oldData, data_format_out);


    %% clean the space for next group
    clear MEG REF oldData startI endI trig

    if exist('chieSorted','var'),  clear EEG; end
    if exist('chixSorted','var'),  clear XTR; end
    if doLineF, clear trig whereUp; end
end

%% wrap up

fclose(fid);
ok=true;
warning('ON', 'MEGanalysis:missingInput:settingBands')

return
