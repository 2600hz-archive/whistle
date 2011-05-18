%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Manage starting fs_auth, fs_route, and fs_node handlers
%%% @end
%%% Created : 17 May 2011 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(ecallmgr_fs_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_handlers/2, stop_handlers/1, get_handler_pids/1]).

%% Supervisor callbacks
-export([init/1]).

-include("ecallmgr.hrl").

-define(SERVER, ?MODULE).
-define(CHILD(Name, Mod, Args), {Name, {Mod, start_link, Args}, temporary, 5000, worker, [Mod]}).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec(start_handlers/2 :: (Node :: atom(), Options :: proplist()) -> list(tuple(ok, pid()))).
start_handlers(Node, Options) when is_atom(Node) ->
    NodeB = whistle_util:to_binary(Node),
    [ begin
	  Name = whistle_util:to_atom(<<NodeB/binary, H/binary>>, true),
	  Mod = whistle_util:to_atom(<<"ecallmgr_fs", H/binary>>),
	  supervisor:start_child(?SERVER, ?CHILD(Name, Mod, [Node, Options]))
      end
      || H <- [<<"_auth">>, <<"_route">>, <<"_node">>] ].

-spec(stop_handlers/1 :: (Node :: atom()) -> no_return()).
stop_handlers(Node) when is_atom(Node) ->
    NodeB = whistle_util:to_binary(Node),
    [ begin
	  ok = supervisor:terminate_child(?SERVER, Name),
	  supervisor:delete_child(?SERVER, Name)
      end || {Name, _, _, [_]} <- supervisor:which_children(?SERVER)
		 ,node_matches(NodeB, whistle_util:to_binary(Name))
    ].
    

-spec(get_handler_pids/1 :: (Node :: atom()) -> tuple(pid() | undefined, pid() | undefined, pid() | undefined)).
get_handler_pids(Node) when is_atom(Node) ->
    NodeB = whistle_util:to_binary(Node),
    NodePids = [ {HandlerMod, Pid} || {Name, Pid, worker, [HandlerMod]} <- supervisor:which_children(?SERVER)
					  ,node_matches(NodeB, whistle_util:to_binary(Name))],
    {
      props:get_value(ecallmgr_fs_auth, NodePids, error)
     ,props:get_value(ecallmgr_fs_route, NodePids, error)
     ,props:get_value(ecallmgr_fs_node, NodePids, error)
    }.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    RestartStrategy = one_for_one,
    MaxRestarts = 1,
    MaxSecondsBetweenRestarts = 5,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    {ok, {SupFlags, []}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(node_matches/2 :: (NodeB :: binary(), Name :: binary()) -> boolean()).
node_matches(NodeB, Name) ->
    Size = byte_size(NodeB),
    case binary:match(Name, NodeB) of
	{_, End} -> Size =:= End;
	nomatch -> false
    end.
