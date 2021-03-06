
-module(trunkstore_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================
-spec(start_link/0 :: () -> tuple(ok, pid()) | ignore | tuple(error, term())).
start_link() ->
    trunkstore:start_deps(),
    trunkstore_app:revise_views(),
    trunkstore_app:setup_base_docs(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}
	   , [
	      ?CHILD(ts_responder_sup, supervisor) %% manages responders to AMQP requests
	      ,?CHILD(ts_responder, worker)
	      ,?CHILD(ts_acctmgr, worker) %% handles reserving/releasing trunks
	      ,?CHILD(ts_credit, worker)  %% handles looking up rating info on the To-DID
	      ,?CHILD(ts_onnet_sup, supervisor) %% handles calls originating on-net (customer)
	      ,?CHILD(ts_offnet_sup, supervisor) %% handles calls originating off-net (carrier)
	      ,?CHILD(ts_cdr, worker)
	     ]} }.
