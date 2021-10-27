function replace_data_block(obj, data, lat, chans)
% REPLACE_DATA_BLOCK replace_data_block(obj, data, lat, chans)
% obj   - is the PDF object into which data is to be replaced
% data  - is nchannels by nlatency matrix
% lat   - first latency index, default is 1
% chans - the channels to rewrite they should come sorted by channel name 
%         of MEG data, as provided by: 
%         >> chi = channel_index(obj,'meg');
%         >> chn = channel_name(obj,chi);
%         >> [chnSorted, chiSorted] = sortMEGnames(chn,chi);
%         It is assumed that data is given in increasing order of channel
%         numbers (e.g. 1,2,3,...248)

% Nov_2008  MA

%not enough argins
if nargin < 2
    error('Too few input argumets');
end

%default value for latency index
if nargin < 3
    lat = 1;
end
lat = round(lat);
if lat <=0, lat=1; end

if ~exist('chans','var'), chans = []; end
numChans = size(data,1);
if isempty(chans)
    chi = channel_index(obj,'meg'); end
    chn = channel_name(obj,chi);
    [chnSorted, chans] = sortMEGnames(chn,chi);

if numChans > length(chans)
    chans = chans(1:numChans);  %  truncate
end
%pdf header
header = get(obj, 'Header');

%empty header means no pdf
if isempty(header)
    error('Need pdf to write data')
end

%total number of channels in pdf
total_chans = double(header.header_data.total_chans);

%BTi Data Formats:
SHORT   =	1;
LONG    =	2;
FLOAT   =	3;
DOUBLE  =	4;

switch header.header_data.data_format
    case SHORT
        data_format = 'int16';
        time_slice_size = 2 * total_chans;
        config = get(obj, 'config');
        if isempty(config)
            error('No Config: Could not scale data\n');
        end
        scale = channel_scale(config, header, 1:total_chans);
        data = int16(data ./ repmat(scale', 1, size(data,2)));
    case LONG
        data_format = 'int32';
        time_slice_size = 4 * total_chans;
        config = get(obj, 'config');
        if isempty(config)
            error('No Config: Could not scale data\n');
        end
        scale = channel_scale(config, header, 1:total_chans);
        data = int32(data ./ repmat(scale', 1, size(data,2)));
    case FLOAT
        data_format = 'float32';
        time_slice_size = 4 * total_chans;
        data = single(data);
    case DOUBLE
        data_format = 'double';
        time_slice_size = 8 * total_chans;
        data = double(data);
    otherwise
        error('Wrong data format : %d\n', header.header_data.data_format);
end
%%%%%%%%%%%%%%%% read the data block to be replaced
%%%%%%%%%%%%%%%% writing data

%open file (to read and write), always big endean
fid = fopen(obj.FileName, 'r+', 'b');

if fid == -1
    error('Cannot open file %s', obj.FileName);
end

%skip some time slices
lat = round(lat);
status = fseek(fid, time_slice_size * (lat-1), 'bof');
if status~=0
    error('MEGanalysis:pdf:fileOperation', ['Did not advance the file ' ferror(fid)])
    fclose(fid)
end
% Read the old data and replace with new
oldData = fread(fid, [total_chans, size(data,2)], data_format);
oldData(chans,:) = data;  % replace the channels

status = fseek(fid, time_slice_size * (lat-1), 'bof');
if status~=0
    error('MEGanalysis:pdf:fileOperation', ['Did not advance the file ' ferror(fid)])
    fclose(fid)
end

fwrite(fid, oldData, data_format);

%close data file
fclose(fid);
