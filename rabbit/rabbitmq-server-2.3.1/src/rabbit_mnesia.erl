%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%


-module(rabbit_mnesia).

-export([ensure_mnesia_dir/0, dir/0, status/0, init/0, is_db_empty/0,
         cluster/1, force_cluster/1, reset/0, force_reset/0,
         is_clustered/0, running_clustered_nodes/0, all_clustered_nodes/0,
         empty_ram_only_tables/0, copy_db/1]).

-export([table_names/0]).

%% create_tables/0 exported for helping embed RabbitMQ in or alongside
%% other mnesia-using Erlang applications, such as ejabberd
-export([create_tables/0]).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([node_type/0]).

-type(node_type() :: disc_only | disc | ram | unknown).
-spec(status/0 :: () -> [{'nodes', [{node_type(), [node()]}]} |
                         {'running_nodes', [node()]}]).
-spec(dir/0 :: () -> file:filename()).
-spec(ensure_mnesia_dir/0 :: () -> 'ok').
-spec(init/0 :: () -> 'ok').
-spec(is_db_empty/0 :: () -> boolean()).
-spec(cluster/1 :: ([node()]) -> 'ok').
-spec(force_cluster/1 :: ([node()]) -> 'ok').
-spec(cluster/2 :: ([node()], boolean()) -> 'ok').
-spec(reset/0 :: () -> 'ok').
-spec(force_reset/0 :: () -> 'ok').
-spec(is_clustered/0 :: () -> boolean()).
-spec(running_clustered_nodes/0 :: () -> [node()]).
-spec(all_clustered_nodes/0 :: () -> [node()]).
-spec(empty_ram_only_tables/0 :: () -> 'ok').
-spec(create_tables/0 :: () -> 'ok').
-spec(copy_db/1 :: (file:filename()) ->  rabbit_types:ok_or_error(any())).

-endif.

%%----------------------------------------------------------------------------

status() ->
    [{nodes, case mnesia:system_info(is_running) of
                 yes -> [{Key, Nodes} ||
                            {Key, CopyType} <- [{disc_only, disc_only_copies},
                                                {disc,      disc_copies},
                                                {ram,       ram_copies}],
                            begin
                                Nodes = nodes_of_type(CopyType),
                                Nodes =/= []
                            end];
                 no -> case all_clustered_nodes() of
                           [] -> [];
                           Nodes -> [{unknown, Nodes}]
                       end
             end},
     {running_nodes, running_clustered_nodes()}].

init() ->
    ok = ensure_mnesia_running(),
    ok = ensure_mnesia_dir(),
    ok = init_db(read_cluster_nodes_config(), true),
    ok.

is_db_empty() ->
    lists:all(fun (Tab) -> mnesia:dirty_first(Tab) == '$end_of_table' end,
              table_names()).

cluster(ClusterNodes) ->
    cluster(ClusterNodes, false).
force_cluster(ClusterNodes) ->
    cluster(ClusterNodes, true).

%% Alter which disk nodes this node is clustered with. This can be a
%% subset of all the disk nodes in the cluster but can (and should)
%% include the node itself if it is to be a disk rather than a ram
%% node.  If Force is false, only connections to online nodes are
%% allowed.
cluster(ClusterNodes, Force) ->
    ok = ensure_mnesia_not_running(),
    ok = ensure_mnesia_dir(),
    rabbit_misc:ensure_ok(mnesia:start(), cannot_start_mnesia),
    try
        ok = init_db(ClusterNodes, Force),
        ok = create_cluster_nodes_config(ClusterNodes)
    after
        mnesia:stop()
    end,
    ok.

%% return node to its virgin state, where it is not member of any
%% cluster, has no cluster configuration, no local database, and no
%% persisted messages
reset()       -> reset(false).
force_reset() -> reset(true).

is_clustered() ->
    RunningNodes = running_clustered_nodes(),
    [node()] /= RunningNodes andalso [] /= RunningNodes.

all_clustered_nodes() ->
    mnesia:system_info(db_nodes).

running_clustered_nodes() ->
    mnesia:system_info(running_db_nodes).

empty_ram_only_tables() ->
    Node = node(),
    lists:foreach(
      fun (TabName) ->
          case lists:member(Node, mnesia:table_info(TabName, ram_copies)) of
              true  -> {atomic, ok} = mnesia:clear_table(TabName);
              false -> ok
          end
      end, table_names()),
    ok.

%%--------------------------------------------------------------------

nodes_of_type(Type) ->
    %% This function should return the nodes of a certain type (ram,
    %% disc or disc_only) in the current cluster.  The type of nodes
    %% is determined when the cluster is initially configured.
    %% Specifically, we check whether a certain table, which we know
    %% will be written to disk on a disc node, is stored on disk or in
    %% RAM.
    mnesia:table_info(rabbit_durable_exchange, Type).

table_definitions() ->
    [{rabbit_user,
      [{record_name, internal_user},
       {attributes, record_info(fields, internal_user)},
       {disc_copies, [node()]},
       {match, #internal_user{_='_'}}]},
     {rabbit_user_permission,
      [{record_name, user_permission},
       {attributes, record_info(fields, user_permission)},
       {disc_copies, [node()]},
       {match, #user_permission{user_vhost = #user_vhost{_='_'},
                                permission = #permission{_='_'},
                                _='_'}}]},
     {rabbit_vhost,
      [{record_name, vhost},
       {attributes, record_info(fields, vhost)},
       {disc_copies, [node()]},
       {match, #vhost{_='_'}}]},
     {rabbit_listener,
      [{record_name, listener},
       {attributes, record_info(fields, listener)},
       {type, bag},
       {match, #listener{_='_'}}]},
     {rabbit_durable_route,
      [{record_name, route},
       {attributes, record_info(fields, route)},
       {disc_copies, [node()]},
       {match, #route{binding = binding_match(), _='_'}}]},
     {rabbit_route,
      [{record_name, route},
       {attributes, record_info(fields, route)},
       {type, ordered_set},
       {match, #route{binding = binding_match(), _='_'}}]},
     {rabbit_reverse_route,
      [{record_name, reverse_route},
       {attributes, record_info(fields, reverse_route)},
       {type, ordered_set},
       {match, #reverse_route{reverse_binding = reverse_binding_match(),
                              _='_'}}]},
     %% Consider the implications to nodes_of_type/1 before altering
     %% the next entry.
     {rabbit_durable_exchange,
      [{record_name, exchange},
       {attributes, record_info(fields, exchange)},
       {disc_copies, [node()]},
       {match, #exchange{name = exchange_name_match(), _='_'}}]},
     {rabbit_exchange,
      [{record_name, exchange},
       {attributes, record_info(fields, exchange)},
       {match, #exchange{name = exchange_name_match(), _='_'}}]},
     {rabbit_durable_queue,
      [{record_name, amqqueue},
       {attributes, record_info(fields, amqqueue)},
       {disc_copies, [node()]},
       {match, #amqqueue{name = queue_name_match(), _='_'}}]},
     {rabbit_queue,
      [{record_name, amqqueue},
       {attributes, record_info(fields, amqqueue)},
       {match, #amqqueue{name = queue_name_match(), _='_'}}]}].

binding_match() ->
    #binding{source = exchange_name_match(),
             destination = binding_destination_match(),
             _='_'}.
reverse_binding_match() ->
    #reverse_binding{destination = binding_destination_match(),
                     source = exchange_name_match(),
                     _='_'}.
binding_destination_match() ->
    resource_match('_').
exchange_name_match() ->
    resource_match(exchange).
queue_name_match() ->
    resource_match(queue).
resource_match(Kind) ->
    #resource{kind = Kind, _='_'}.

table_names() ->
    [Tab || {Tab, _} <- table_definitions()].

replicated_table_names() ->
    [Tab || {Tab, TabDef} <- table_definitions(),
            not lists:member({local_content, true}, TabDef)
    ].

dir() -> mnesia:system_info(directory).

ensure_mnesia_dir() ->
    MnesiaDir = dir() ++ "/",
    case filelib:ensure_dir(MnesiaDir) of
        {error, Reason} ->
            throw({error, {cannot_create_mnesia_dir, MnesiaDir, Reason}});
        ok ->
            ok
    end.

ensure_mnesia_running() ->
    case mnesia:system_info(is_running) of
        yes -> ok;
        no  -> throw({error, mnesia_not_running})
    end.

ensure_mnesia_not_running() ->
    case mnesia:system_info(is_running) of
        no  -> ok;
        yes -> throw({error, mnesia_unexpectedly_running})
    end.

ensure_schema_integrity() ->
    case check_schema_integrity() of
        ok ->
            ok;
        {error, Reason} ->
            throw({error, {schema_integrity_check_failed, Reason}})
    end.

check_schema_integrity() ->
    Tables = mnesia:system_info(tables),
    case [Error || {Tab, TabDef} <- table_definitions(),
                   case lists:member(Tab, Tables) of
                       false ->
                           Error = {table_missing, Tab},
                           true;
                       true  ->
                           {_, ExpAttrs} = proplists:lookup(attributes, TabDef),
                           Attrs = mnesia:table_info(Tab, attributes),
                           Error = {table_attributes_mismatch, Tab,
                                    ExpAttrs, Attrs},
                           Attrs /= ExpAttrs
                   end] of
        []     -> check_table_integrity();
        Errors -> {error, Errors}
    end.

check_table_integrity() ->
    ok = wait_for_tables(),
    case lists:all(fun ({Tab, TabDef}) ->
                           {_, Match} = proplists:lookup(match, TabDef),
                           read_test_table(Tab, Match)
                   end, table_definitions()) of
        true  -> ok;
        false -> {error, invalid_table_content}
    end.

read_test_table(Tab, Match) ->
    case mnesia:dirty_first(Tab) of
        '$end_of_table' ->
            true;
        Key ->
            ObjList = mnesia:dirty_read(Tab, Key),
            MatchComp = ets:match_spec_compile([{Match, [], ['$_']}]),
            case ets:match_spec_run(ObjList, MatchComp) of
                ObjList -> true;
                _       -> false
            end
    end.

%% The cluster node config file contains some or all of the disk nodes
%% that are members of the cluster this node is / should be a part of.
%%
%% If the file is absent, the list is empty, or only contains the
%% current node, then the current node is a standalone (disk)
%% node. Otherwise it is a node that is part of a cluster as either a
%% disk node, if it appears in the cluster node config, or ram node if
%% it doesn't.

cluster_nodes_config_filename() ->
    dir() ++ "/cluster_nodes.config".

create_cluster_nodes_config(ClusterNodes) ->
    FileName = cluster_nodes_config_filename(),
    case rabbit_misc:write_term_file(FileName, [ClusterNodes]) of
        ok -> ok;
        {error, Reason} ->
            throw({error, {cannot_create_cluster_nodes_config,
                           FileName, Reason}})
    end.

read_cluster_nodes_config() ->
    FileName = cluster_nodes_config_filename(),
    case rabbit_misc:read_term_file(FileName) of
        {ok, [ClusterNodes]} -> ClusterNodes;
        {error, enoent} ->
            {ok, ClusterNodes} = application:get_env(rabbit, cluster_nodes),
            ClusterNodes;
        {error, Reason} ->
            throw({error, {cannot_read_cluster_nodes_config,
                           FileName, Reason}})
    end.

delete_cluster_nodes_config() ->
    FileName = cluster_nodes_config_filename(),
    case file:delete(FileName) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} ->
            throw({error, {cannot_delete_cluster_nodes_config,
                           FileName, Reason}})
    end.

%% Take a cluster node config and create the right kind of node - a
%% standalone disk node, or disk or ram node connected to the
%% specified cluster nodes.  If Force is false, don't allow
%% connections to offline nodes.
init_db(ClusterNodes, Force) ->
    UClusterNodes = lists:usort(ClusterNodes),
    ProperClusterNodes = UClusterNodes -- [node()],
    case mnesia:change_config(extra_db_nodes, ProperClusterNodes) of
        {ok, Nodes} ->
            case Force of
                false -> FailedClusterNodes = ProperClusterNodes -- Nodes,
                         case FailedClusterNodes of
                             [] -> ok;
                             _  -> throw({error, {failed_to_cluster_with,
                                                  FailedClusterNodes,
                                                  "Mnesia could not connect "
                                                  "to some nodes."}})
                         end;
                true  -> ok
            end,
            case {Nodes, mnesia:system_info(use_dir), all_clustered_nodes()} of
                {[], true, [_]} ->
                    %% True single disc node, attempt upgrade
                    ok = wait_for_tables(),
                    case rabbit_upgrade:maybe_upgrade() of
                        ok                    -> ensure_schema_ok();
                        version_not_available -> schema_ok_or_move()
                    end;
                {[], true, _} ->
                    %% "Master" (i.e. without config) disc node in cluster,
                    %% verify schema
                    ok = wait_for_tables(),
                    ensure_version_ok(rabbit_upgrade:read_version()),
                    ensure_schema_ok();
                {[], false, _} ->
                    %% Nothing there at all, start from scratch
                    ok = create_schema();
                {[AnotherNode|_], _, _} ->
                    %% Subsequent node in cluster, catch up
                    ensure_version_ok(rabbit_upgrade:read_version()),
                    ensure_version_ok(
                      rpc:call(AnotherNode, rabbit_upgrade, read_version, [])),
                    IsDiskNode = ClusterNodes == [] orelse
                        lists:member(node(), ClusterNodes),
                    ok = wait_for_replicated_tables(),
                    ok = create_local_table_copy(schema, disc_copies),
                    ok = create_local_table_copies(case IsDiskNode of
                                                       true  -> disc;
                                                       false -> ram
                                                   end),
                    ensure_schema_ok()
            end;
        {error, Reason} ->
            %% one reason we may end up here is if we try to join
            %% nodes together that are currently running standalone or
            %% are members of a different cluster
            throw({error, {unable_to_join_cluster, ClusterNodes, Reason}})
    end.

schema_ok_or_move() ->
    case check_schema_integrity() of
        ok ->
            ok;
        {error, Reason} ->
            %% NB: we cannot use rabbit_log here since it may not have been
            %% started yet
            error_logger:warning_msg("schema integrity check failed: ~p~n"
                                     "moving database to backup location "
                                     "and recreating schema from scratch~n",
                                     [Reason]),
            ok = move_db(),
            ok = create_schema()
    end.

ensure_version_ok({ok, DiscVersion}) ->
    case rabbit_upgrade:desired_version() of
        DiscVersion    ->  ok;
        DesiredVersion ->  throw({error, {schema_mismatch,
                                          DesiredVersion, DiscVersion}})
    end;
ensure_version_ok({error, _}) ->
    ok = rabbit_upgrade:write_version().

ensure_schema_ok() ->
    case check_schema_integrity() of
        ok              -> ok;
        {error, Reason} -> throw({error, {schema_invalid, Reason}})
    end.

create_schema() ->
    mnesia:stop(),
    rabbit_misc:ensure_ok(mnesia:create_schema([node()]),
                          cannot_create_schema),
    rabbit_misc:ensure_ok(mnesia:start(),
                          cannot_start_mnesia),
    ok = create_tables(),
    ok = ensure_schema_integrity(),
    ok = wait_for_tables(),
    ok = rabbit_upgrade:write_version().

move_db() ->
    mnesia:stop(),
    MnesiaDir = filename:dirname(dir() ++ "/"),
    {{Year, Month, Day}, {Hour, Minute, Second}} = erlang:universaltime(),
    BackupDir = lists:flatten(
                  io_lib:format("~s_~w~2..0w~2..0w~2..0w~2..0w~2..0w",
                                [MnesiaDir,
                                 Year, Month, Day, Hour, Minute, Second])),
    case file:rename(MnesiaDir, BackupDir) of
        ok ->
            %% NB: we cannot use rabbit_log here since it may not have
            %% been started yet
            error_logger:warning_msg("moved database from ~s to ~s~n",
                                     [MnesiaDir, BackupDir]),
            ok;
        {error, Reason} -> throw({error, {cannot_backup_mnesia,
                                          MnesiaDir, BackupDir, Reason}})
    end,
    ok = ensure_mnesia_dir(),
    rabbit_misc:ensure_ok(mnesia:start(), cannot_start_mnesia),
    ok.

copy_db(Destination) ->
    mnesia:stop(),
    case rabbit_misc:recursive_copy(dir(), Destination) of
        ok ->
            rabbit_misc:ensure_ok(mnesia:start(), cannot_start_mnesia),
            ok = wait_for_tables();
        {error, E} ->
            {error, E}
    end.

create_tables() ->
    lists:foreach(fun ({Tab, TabDef}) ->
                          TabDef1 = proplists:delete(match, TabDef),
                          case mnesia:create_table(Tab, TabDef1) of
                              {atomic, ok} -> ok;
                              {aborted, Reason} ->
                                  throw({error, {table_creation_failed,
                                                 Tab, TabDef1, Reason}})
                          end
                  end,
                  table_definitions()),
    ok.

table_has_copy_type(TabDef, DiscType) ->
    lists:member(node(), proplists:get_value(DiscType, TabDef, [])).

create_local_table_copies(Type) ->
    lists:foreach(
      fun ({Tab, TabDef}) ->
              HasDiscCopies     = table_has_copy_type(TabDef, disc_copies),
              HasDiscOnlyCopies = table_has_copy_type(TabDef, disc_only_copies),
              LocalTab          = proplists:get_bool(local_content, TabDef),
              StorageType =
                  if
                      Type =:= disc orelse LocalTab ->
                          if
                              HasDiscCopies     -> disc_copies;
                              HasDiscOnlyCopies -> disc_only_copies;
                              true              -> ram_copies
                          end;
%% unused code - commented out to keep dialyzer happy
%%                      Type =:= disc_only ->
%%                          if
%%                              HasDiscCopies or HasDiscOnlyCopies ->
%%                                  disc_only_copies;
%%                              true -> ram_copies
%%                          end;
                      Type =:= ram ->
                          ram_copies
                  end,
              ok = create_local_table_copy(Tab, StorageType)
      end,
      table_definitions()),
    ok.

create_local_table_copy(Tab, Type) ->
    StorageType = mnesia:table_info(Tab, storage_type),
    {atomic, ok} =
        if
            StorageType == unknown ->
                mnesia:add_table_copy(Tab, node(), Type);
            StorageType /= Type ->
                mnesia:change_table_copy_type(Tab, node(), Type);
            true -> {atomic, ok}
        end,
    ok.

wait_for_replicated_tables() -> wait_for_tables(replicated_table_names()).

wait_for_tables() -> wait_for_tables(table_names()).

wait_for_tables(TableNames) ->
    case mnesia:wait_for_tables(TableNames, 30000) of
        ok -> ok;
        {timeout, BadTabs} ->
            throw({error, {timeout_waiting_for_tables, BadTabs}});
        {error, Reason} ->
            throw({error, {failed_waiting_for_tables, Reason}})
    end.

reset(Force) ->
    ok = ensure_mnesia_not_running(),
    Node = node(),
    case Force of
        true  -> ok;
        false ->
            ok = ensure_mnesia_dir(),
            rabbit_misc:ensure_ok(mnesia:start(), cannot_start_mnesia),
            {Nodes, RunningNodes} =
                try
                    ok = init(),
                    {all_clustered_nodes() -- [Node],
                     running_clustered_nodes() -- [Node]}
                after
                    mnesia:stop()
                end,
            leave_cluster(Nodes, RunningNodes),
            rabbit_misc:ensure_ok(mnesia:delete_schema([Node]),
                                  cannot_delete_schema)
    end,
    ok = delete_cluster_nodes_config(),
    %% remove persisted messages and any other garbage we find
    ok = rabbit_misc:recursive_delete(filelib:wildcard(dir() ++ "/*")),
    ok.

leave_cluster([], _) -> ok;
leave_cluster(Nodes, RunningNodes) ->
    %% find at least one running cluster node and instruct it to
    %% remove our schema copy which will in turn result in our node
    %% being removed as a cluster node from the schema, with that
    %% change being propagated to all nodes
    case lists:any(
           fun (Node) ->
                   case rpc:call(Node, mnesia, del_table_copy,
                                 [schema, node()]) of
                       {atomic, ok} -> true;
                       {badrpc, nodedown} -> false;
                       {aborted, Reason} ->
                           throw({error, {failed_to_leave_cluster,
                                          Nodes, RunningNodes, Reason}})
                   end
           end,
           RunningNodes) of
        true -> ok;
        false -> throw({error, {no_running_cluster_nodes,
                                Nodes, RunningNodes}})
    end.
