%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% SHOUTCast related functionality
%%% @end
%%% Created :  6 May 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(wh_shout).

-include_lib("wh_media.hrl").

-export([get_request/1, play_chunk/6, get_shout_srv_response/5, get_shout_header/2]).

-spec(get_request/1 :: (S :: port()) -> void | list()).
get_request(S) ->
    get_request(S, []).

-spec(get_request/2 :: (S :: port(), L :: list()) -> void | list()).
get_request(S, L) ->
    ok = inet:setopts(S, [{active,once}, binary]),
    receive
	{tcp, S, Bin} ->
	    L1 = L ++ binary_to_list(Bin),
	    %% split checks if the header is complete
	    case split(L1, []) of
		more ->
		    %% the header is incomplete we need more data
		    get_request(S, L1);
		{Request, _Rest} ->
		    %% header is complete
		    Request
	    end;

	{tcp_closed, _Socket} ->
	    void
    end.

%% OffSet = first byte to play
%% Stop   = The last byte we can play
-spec(play_chunk/6 :: (MediaFile :: #media_file{}, Socks :: port() | list(port()), Offset :: integer(), Stop :: integer(), SoFar :: binary(), Header :: tuple()) ->
			   tuple(done, list(port())) | %% finished playing the media
			   tuple(list(port()), tuple(), integer(), binary())). %% more media to play
play_chunk(MediaFile, Sock, Offset, Stop, SoFar, Header) when is_port(Sock) ->
    play_chunk(MediaFile, [Sock], Offset, Stop, SoFar, Header);
play_chunk(#media_file{contents=Contents, chunk_size=ChunkSize, pad_response=ToPad}, Socks, Offset, Stop, SoFar, Header) ->
    Need = ChunkSize - byte_size(SoFar),
    Last = Offset + Need,

    case Last >= Stop of
	true ->
	    %% not enough data so read as much as possible and return
	    Max = Stop - Offset,
	    Bin = binary:part(Contents, Offset, Max),
	    StillActive = write_data(Socks, SoFar, Bin, Header, ChunkSize, ToPad),
	    {done, StillActive};
	false ->
	    Bin = binary:part(Contents, Offset, Need),
	    StillActive = write_data(Socks, SoFar, Bin, Header, ChunkSize, ToPad),
	    {StillActive, bump(Header), Offset + Need, <<>>}
    end.

%% return the res
-spec(get_shout_srv_response/5 :: (SrvName :: binary() | string(), MediaName :: binary() | string()
				  ,ChunkSize :: integer(), Url :: binary() | string()
				  ,CT :: binary() | string()) ->
			 iolist()).
get_shout_srv_response(SrvName, MediaName, ChunkSize, Url, CT) ->
    ["ICY 200 OK\r\n",
     "icy-notice1: ", whistle_util:to_list(SrvName), "<BR>\r\n",
     "icy-name: ", whistle_util:to_list(MediaName), "\r\n",
     "icy-genre: Whistle Media\r\n",
     "icy-url: ", whistle_util:to_list(Url) ,"\r\n",
     "content-type: ", whistle_util:to_list(CT), "\r\n",
     "icy-pub: 1\r\n",
     "icy-metaint: ",integer_to_list(ChunkSize),"\r\n",
     "icy-br: 8\r\n\r\n"].

-spec(get_shout_header/2 :: (MediaName :: string() | binary(), Url :: string() | binary()) -> binary()).
get_shout_header(MediaName, Url) ->
    Bin = list_to_binary(["StreamTitle='",whistle_util:to_list(MediaName)
			  ,"';StreamUrl='",whistle_util:to_list(Url) ,"';"]),
    Nblocks = ((byte_size(Bin) - 1) div 16) + 1,
    NPad = Nblocks*16 - byte_size(Bin),
    Extra = lists:duplicate(NPad, 0),
    list_to_binary([Nblocks, Bin, Extra]).

-spec(split/2 :: (Hs :: list(), L :: list()) -> tuple(list(), list()) | 'more').
split([], _) -> more;
split([$\r,$\n,$\r,$\n | T], L) -> {lists:reverse(L), T};
split([H|T], L) -> split(T, [H|L]).

write_data(Sockets, B0, B1, Header, ChunkSize, ToPad) ->
    %% Check that we really have got a block of the right size
    %% this is a very useful check that our program logic is
    %% correct
    case byte_size(B0) + byte_size(B1) of
	ChunkSize ->
	    Send = [B0, B1, the_header(Header)],
	    [S || S <- Sockets,
		  begin
		      Write = gen_tcp:send(S, Send),
		      Write =:= ok
		  end];
	Size when (Size < ChunkSize) andalso ToPad ->
	    H = the_header(Header),
	    Padding = binary:copy(<<0>>, ChunkSize-Size-byte_size(H)),
	    Send = [B0, B1, H, Padding],
	    [ S || S <- Sockets,
		   begin
		       Write = gen_tcp:send(S, Send),
		       Write =:= ok
		   end ];
	Size when (Size < ChunkSize) ->
	    Send = [B0, B1, the_header(Header)],
	    [ S || S <- Sockets,
		   begin
		       Write = gen_tcp:send(S, Send),
		       Write =:= ok
		   end ];
	_Other ->
	    Sockets
    end.

bump(undefined) -> undefined;
bump({K, H}) -> {K+1, H}.

the_header(undefined) ->
    <<>>;
the_header({K, H}) ->
    case K rem 5 of
	0 -> H;
	_ -> <<0>>
    end.
