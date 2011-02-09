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

-module(rabbit_amqqueue).

-export([start/0, stop/0, declare/5, delete_immediately/1, delete/3, purge/1]).
-export([internal_declare/2, internal_delete/1,
         maybe_run_queue_via_backing_queue/2,
         maybe_run_queue_via_backing_queue_async/2,
         sync_timeout/1, update_ram_duration/1, set_ram_duration_target/2,
         set_maximum_since_use/2, maybe_expire/1, drop_expired/1]).
-export([pseudo_queue/2]).
-export([lookup/1, with/2, with_or_die/2, assert_equivalence/5,
         check_exclusive_access/2, with_exclusive_access_or_die/3,
         stat/1, deliver/2, requeue/3, ack/4, reject/4]).
-export([list/1, info_keys/0, info/1, info/2, info_all/1, info_all/2]).
-export([emit_stats/1]).
-export([consumers/1, consumers_all/1]).
-export([basic_get/3, basic_consume/7, basic_cancel/4]).
-export([notify_sent/2, unblock/2, flush_all/2]).
-export([commit_all/3, rollback_all/3, notify_down_all/2, limit_all/3]).
-export([on_node_down/1]).

-include("rabbit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-define(INTEGER_ARG_TYPES, [byte, short, signedint, long]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([name/0, qmsg/0]).

-type(name() :: rabbit_types:r('queue')).

-type(qlen() :: rabbit_types:ok(non_neg_integer())).
-type(qfun(A) :: fun ((rabbit_types:amqqueue()) -> A)).
-type(qmsg() :: {name(), pid(), msg_id(), boolean(), rabbit_types:message()}).
-type(msg_id() :: non_neg_integer()).
-type(ok_or_errors() ::
      'ok' | {'error', [{'error' | 'exit' | 'throw', any()}]}).

-type(queue_or_not_found() :: rabbit_types:amqqueue() | 'not_found').

-spec(start/0 :: () -> 'ok').
-spec(stop/0 :: () -> 'ok').
-spec(declare/5 ::
        (name(), boolean(), boolean(),
         rabbit_framing:amqp_table(), rabbit_types:maybe(pid()))
        -> {'new' | 'existing', rabbit_types:amqqueue()} |
           rabbit_types:channel_exit()).
-spec(lookup/1 ::
        (name()) -> rabbit_types:ok(rabbit_types:amqqueue()) |
                    rabbit_types:error('not_found')).
-spec(with/2 :: (name(), qfun(A)) -> A | rabbit_types:error('not_found')).
-spec(with_or_die/2 ::
        (name(), qfun(A)) -> A | rabbit_types:channel_exit()).
-spec(assert_equivalence/5 ::
        (rabbit_types:amqqueue(), boolean(), boolean(),
         rabbit_framing:amqp_table(), rabbit_types:maybe(pid()))
        -> 'ok' | rabbit_types:channel_exit() |
           rabbit_types:connection_exit()).
-spec(check_exclusive_access/2 ::
        (rabbit_types:amqqueue(), pid())
        -> 'ok' | rabbit_types:channel_exit()).
-spec(with_exclusive_access_or_die/3 ::
        (name(), pid(), qfun(A)) -> A | rabbit_types:channel_exit()).
-spec(list/1 :: (rabbit_types:vhost()) -> [rabbit_types:amqqueue()]).
-spec(info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(info/1 :: (rabbit_types:amqqueue()) -> rabbit_types:infos()).
-spec(info/2 ::
        (rabbit_types:amqqueue(), rabbit_types:info_keys())
        -> rabbit_types:infos()).
-spec(info_all/1 :: (rabbit_types:vhost()) -> [rabbit_types:infos()]).
-spec(info_all/2 :: (rabbit_types:vhost(), rabbit_types:info_keys())
                    -> [rabbit_types:infos()]).
-spec(consumers/1 ::
        (rabbit_types:amqqueue())
        -> [{pid(), rabbit_types:ctag(), boolean()}]).
-spec(consumers_all/1 ::
        (rabbit_types:vhost())
        -> [{name(), pid(), rabbit_types:ctag(), boolean()}]).
-spec(stat/1 ::
        (rabbit_types:amqqueue())
        -> {'ok', non_neg_integer(), non_neg_integer()}).
-spec(emit_stats/1 :: (rabbit_types:amqqueue()) -> 'ok').
-spec(delete_immediately/1 :: (rabbit_types:amqqueue()) -> 'ok').
-spec(delete/3 ::
      (rabbit_types:amqqueue(), 'false', 'false')
        -> qlen();
      (rabbit_types:amqqueue(), 'true' , 'false')
        -> qlen() | rabbit_types:error('in_use');
      (rabbit_types:amqqueue(), 'false', 'true' )
        -> qlen() | rabbit_types:error('not_empty');
      (rabbit_types:amqqueue(), 'true' , 'true' )
        -> qlen() |
           rabbit_types:error('in_use') |
           rabbit_types:error('not_empty')).
-spec(purge/1 :: (rabbit_types:amqqueue()) -> qlen()).
-spec(deliver/2 :: (pid(), rabbit_types:delivery()) -> boolean()).
-spec(requeue/3 :: (pid(), [msg_id()],  pid()) -> 'ok').
-spec(ack/4 ::
        (pid(), rabbit_types:maybe(rabbit_types:txn()), [msg_id()], pid())
        -> 'ok').
-spec(reject/4 :: (pid(), [msg_id()], boolean(), pid()) -> 'ok').
-spec(commit_all/3 :: ([pid()], rabbit_types:txn(), pid()) -> ok_or_errors()).
-spec(rollback_all/3 :: ([pid()], rabbit_types:txn(), pid()) -> 'ok').
-spec(notify_down_all/2 :: ([pid()], pid()) -> ok_or_errors()).
-spec(limit_all/3 :: ([pid()], pid(), pid() | 'undefined') -> ok_or_errors()).
-spec(basic_get/3 :: (rabbit_types:amqqueue(), pid(), boolean()) ->
             {'ok', non_neg_integer(), qmsg()} | 'empty').
-spec(basic_consume/7 ::
      (rabbit_types:amqqueue(), boolean(), pid(), pid() | 'undefined',
       rabbit_types:ctag(), boolean(), any())
        -> rabbit_types:ok_or_error('exclusive_consume_unavailable')).
-spec(basic_cancel/4 ::
        (rabbit_types:amqqueue(), pid(), rabbit_types:ctag(), any()) -> 'ok').
-spec(notify_sent/2 :: (pid(), pid()) -> 'ok').
-spec(unblock/2 :: (pid(), pid()) -> 'ok').
-spec(flush_all/2 :: ([pid()], pid()) -> 'ok').
-spec(internal_declare/2 ::
        (rabbit_types:amqqueue(), boolean())
        -> queue_or_not_found() | rabbit_misc:thunk(queue_or_not_found())).
-spec(internal_delete/1 ::
        (name()) -> rabbit_types:ok_or_error('not_found') |
                    rabbit_types:connection_exit() |
                    fun ((boolean()) -> rabbit_types:ok_or_error('not_found') |
                                        rabbit_types:connection_exit())).
-spec(maybe_run_queue_via_backing_queue/2 ::
        (pid(), (fun ((A) -> {[rabbit_guid:guid()], A}))) -> 'ok').
-spec(maybe_run_queue_via_backing_queue_async/2 ::
        (pid(), (fun ((A) -> {[rabbit_guid:guid()], A}))) -> 'ok').
-spec(sync_timeout/1 :: (pid()) -> 'ok').
-spec(update_ram_duration/1 :: (pid()) -> 'ok').
-spec(set_ram_duration_target/2 :: (pid(), number() | 'infinity') -> 'ok').
-spec(set_maximum_since_use/2 :: (pid(), non_neg_integer()) -> 'ok').
-spec(maybe_expire/1 :: (pid()) -> 'ok').
-spec(on_node_down/1 :: (node()) -> 'ok').
-spec(pseudo_queue/2 :: (name(), pid()) -> rabbit_types:amqqueue()).

-endif.

%%----------------------------------------------------------------------------

start() ->
    DurableQueues = find_durable_queues(),
    {ok, BQ} = application:get_env(rabbit, backing_queue_module),
    ok = BQ:start([QName || #amqqueue{name = QName} <- DurableQueues]),
    {ok,_} = supervisor:start_child(
               rabbit_sup,
               {rabbit_amqqueue_sup,
                {rabbit_amqqueue_sup, start_link, []},
                transient, infinity, supervisor, [rabbit_amqqueue_sup]}),
    _RealDurableQueues = recover_durable_queues(DurableQueues),
    ok.

stop() ->
    ok = supervisor:terminate_child(rabbit_sup, rabbit_amqqueue_sup),
    ok = supervisor:delete_child(rabbit_sup, rabbit_amqqueue_sup),
    {ok, BQ} = application:get_env(rabbit, backing_queue_module),
    ok = BQ:stop().

find_durable_queues() ->
    Node = node(),
    %% TODO: use dirty ops instead
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              qlc:e(qlc:q([Q || Q = #amqqueue{pid = Pid}
                                    <- mnesia:table(rabbit_durable_queue),
                                node(Pid) == Node]))
      end).

recover_durable_queues(DurableQueues) ->
    Qs = [start_queue_process(Q) || Q <- DurableQueues],
    [Q || Q <- Qs,
          gen_server2:call(Q#amqqueue.pid, {init, true}, infinity) == Q].

declare(QueueName, Durable, AutoDelete, Args, Owner) ->
    ok = check_declare_arguments(QueueName, Args),
    Q = start_queue_process(#amqqueue{name = QueueName,
                                      durable = Durable,
                                      auto_delete = AutoDelete,
                                      arguments = Args,
                                      exclusive_owner = Owner,
                                      pid = none}),
    case gen_server2:call(Q#amqqueue.pid, {init, false}) of
        not_found -> rabbit_misc:not_found(QueueName);
        Q1        -> Q1
    end.

internal_declare(Q, true) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () -> ok = store_queue(Q), rabbit_misc:const(Q) end);
internal_declare(Q = #amqqueue{name = QueueName}, false) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () ->
              case mnesia:wread({rabbit_queue, QueueName}) of
                  [] ->
                      case mnesia:read({rabbit_durable_queue, QueueName}) of
                          []  -> ok = store_queue(Q),
                                 B = add_default_binding(Q),
                                 fun (Tx) -> B(Tx), Q end;
                          [_] -> %% Q exists on stopped node
                                 rabbit_misc:const(not_found)
                      end;
                  [ExistingQ = #amqqueue{pid = QPid}] ->
                      case is_process_alive(QPid) of
                          true  -> rabbit_misc:const(ExistingQ);
                          false -> TailFun = internal_delete(QueueName),
                                   fun (Tx) -> TailFun(Tx), ExistingQ end
                      end
              end
      end).

store_queue(Q = #amqqueue{durable = true}) ->
    ok = mnesia:write(rabbit_durable_queue, Q, write),
    ok = mnesia:write(rabbit_queue, Q, write),
    ok;
store_queue(Q = #amqqueue{durable = false}) ->
    ok = mnesia:write(rabbit_queue, Q, write),
    ok.

start_queue_process(Q) ->
    {ok, Pid} = rabbit_amqqueue_sup:start_child([Q]),
    Q#amqqueue{pid = Pid}.

add_default_binding(#amqqueue{name = QueueName}) ->
    ExchangeName = rabbit_misc:r(QueueName, exchange, <<>>),
    RoutingKey = QueueName#resource.name,
    rabbit_binding:add(#binding{source      = ExchangeName,
                                destination = QueueName,
                                key         = RoutingKey,
                                args        = []}).

lookup(Name) ->
    rabbit_misc:dirty_read({rabbit_queue, Name}).

with(Name, F, E) ->
    case lookup(Name) of
        {ok, Q} -> rabbit_misc:with_exit_handler(E, fun () -> F(Q) end);
        {error, not_found} -> E()
    end.

with(Name, F) ->
    with(Name, F, fun () -> {error, not_found} end).
with_or_die(Name, F) ->
    with(Name, F, fun () -> rabbit_misc:not_found(Name) end).

assert_equivalence(#amqqueue{durable     = Durable,
                             auto_delete = AutoDelete} = Q,
                   Durable, AutoDelete, RequiredArgs, Owner) ->
    assert_args_equivalence(Q, RequiredArgs),
    check_exclusive_access(Q, Owner, strict);
assert_equivalence(#amqqueue{name = QueueName},
                   _Durable, _AutoDelete, _RequiredArgs, _Owner) ->
    rabbit_misc:protocol_error(
      precondition_failed, "parameters for ~s not equivalent",
      [rabbit_misc:rs(QueueName)]).

check_exclusive_access(Q, Owner) -> check_exclusive_access(Q, Owner, lax).

check_exclusive_access(#amqqueue{exclusive_owner = Owner}, Owner, _MatchType) ->
    ok;
check_exclusive_access(#amqqueue{exclusive_owner = none}, _ReaderPid, lax) ->
    ok;
check_exclusive_access(#amqqueue{name = QueueName}, _ReaderPid, _MatchType) ->
    rabbit_misc:protocol_error(
      resource_locked,
      "cannot obtain exclusive access to locked ~s",
      [rabbit_misc:rs(QueueName)]).

with_exclusive_access_or_die(Name, ReaderPid, F) ->
    with_or_die(Name,
                fun (Q) -> check_exclusive_access(Q, ReaderPid), F(Q) end).

assert_args_equivalence(#amqqueue{name = QueueName, arguments = Args},
                       RequiredArgs) ->
    rabbit_misc:assert_args_equivalence(Args, RequiredArgs, QueueName,
                                        [<<"x-expires">>]).

check_declare_arguments(QueueName, Args) ->
    [case Fun(rabbit_misc:table_lookup(Args, Key)) of
         ok             -> ok;
         {error, Error} -> rabbit_misc:protocol_error(
                             precondition_failed,
                             "invalid arg '~s' for ~s: ~w",
                             [Key, rabbit_misc:rs(QueueName), Error])
     end || {Key, Fun} <-
                [{<<"x-expires">>,     fun check_expires_argument/1},
                 {<<"x-message-ttl">>, fun check_message_ttl_argument/1}]],
    ok.

check_expires_argument(Val) ->
    check_integer_argument(Val,
                           expires_not_of_acceptable_type,
                           expires_zero_or_less).

check_message_ttl_argument(Val) ->
    check_integer_argument(Val,
                           ttl_not_of_acceptable_type,
                           ttl_zero_or_less).

check_integer_argument(undefined, _, _) ->
    ok;
check_integer_argument({Type, Val}, InvalidTypeError, _) when Val > 0 ->
    case lists:member(Type, ?INTEGER_ARG_TYPES) of
        true  -> ok;
        false -> {error, {InvalidTypeError, Type, Val}}
    end;
check_integer_argument({_Type, _Val}, _, ZeroOrLessError) ->
    {error, ZeroOrLessError}.

list(VHostPath) ->
    mnesia:dirty_match_object(
      rabbit_queue,
      #amqqueue{name = rabbit_misc:r(VHostPath, queue), _ = '_'}).

info_keys() -> rabbit_amqqueue_process:info_keys().

map(VHostPath, F) -> rabbit_misc:filter_exit_map(F, list(VHostPath)).

info(#amqqueue{ pid = QPid }) ->
    delegate_call(QPid, info, infinity).

info(#amqqueue{ pid = QPid }, Items) ->
    case delegate_call(QPid, {info, Items}, infinity) of
        {ok, Res}      -> Res;
        {error, Error} -> throw(Error)
    end.

info_all(VHostPath) -> map(VHostPath, fun (Q) -> info(Q) end).

info_all(VHostPath, Items) -> map(VHostPath, fun (Q) -> info(Q, Items) end).

consumers(#amqqueue{ pid = QPid }) ->
    delegate_call(QPid, consumers, infinity).

consumers_all(VHostPath) ->
    lists:append(
      map(VHostPath,
          fun (Q) -> [{Q#amqqueue.name, ChPid, ConsumerTag, AckRequired} ||
                         {ChPid, ConsumerTag, AckRequired} <- consumers(Q)]
          end)).

stat(#amqqueue{pid = QPid}) -> delegate_call(QPid, stat, infinity).

emit_stats(#amqqueue{pid = QPid}) ->
    delegate_cast(QPid, emit_stats).

delete_immediately(#amqqueue{ pid = QPid }) ->
    gen_server2:cast(QPid, delete_immediately).

delete(#amqqueue{ pid = QPid }, IfUnused, IfEmpty) ->
    delegate_call(QPid, {delete, IfUnused, IfEmpty}, infinity).

purge(#amqqueue{ pid = QPid }) -> delegate_call(QPid, purge, infinity).

deliver(QPid, Delivery = #delivery{immediate = true}) ->
    gen_server2:call(QPid, {deliver_immediately, Delivery}, infinity);
deliver(QPid, Delivery = #delivery{mandatory = true}) ->
    gen_server2:call(QPid, {deliver, Delivery}, infinity),
    true;
deliver(QPid, Delivery) ->
    gen_server2:cast(QPid, {deliver, Delivery}),
    true.

requeue(QPid, MsgIds, ChPid) ->
    delegate_call(QPid, {requeue, MsgIds, ChPid}, infinity).

ack(QPid, Txn, MsgIds, ChPid) ->
    delegate_cast(QPid, {ack, Txn, MsgIds, ChPid}).

reject(QPid, MsgIds, Requeue, ChPid) ->
    delegate_cast(QPid, {reject, MsgIds, Requeue, ChPid}).

commit_all(QPids, Txn, ChPid) ->
    safe_delegate_call_ok(
      fun (QPid) -> gen_server2:call(QPid, {commit, Txn, ChPid}, infinity) end,
      QPids).

rollback_all(QPids, Txn, ChPid) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) -> gen_server2:cast(QPid, {rollback, Txn, ChPid}) end).

notify_down_all(QPids, ChPid) ->
    safe_delegate_call_ok(
      fun (QPid) -> gen_server2:call(QPid, {notify_down, ChPid}, infinity) end,
      QPids).

limit_all(QPids, ChPid, LimiterPid) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) ->
                     gen_server2:cast(QPid, {limit, ChPid, LimiterPid})
             end).

basic_get(#amqqueue{pid = QPid}, ChPid, NoAck) ->
    delegate_call(QPid, {basic_get, ChPid, NoAck}, infinity).

basic_consume(#amqqueue{pid = QPid}, NoAck, ChPid, LimiterPid,
              ConsumerTag, ExclusiveConsume, OkMsg) ->
    delegate_call(QPid, {basic_consume, NoAck, ChPid,
                         LimiterPid, ConsumerTag, ExclusiveConsume, OkMsg},
                  infinity).

basic_cancel(#amqqueue{pid = QPid}, ChPid, ConsumerTag, OkMsg) ->
    ok = delegate_call(QPid, {basic_cancel, ChPid, ConsumerTag, OkMsg},
                       infinity).

notify_sent(QPid, ChPid) ->
    delegate_cast(QPid, {notify_sent, ChPid}).

unblock(QPid, ChPid) ->
    delegate_cast(QPid, {unblock, ChPid}).

flush_all(QPids, ChPid) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) -> gen_server2:cast(QPid, {flush, ChPid}) end).

internal_delete1(QueueName) ->
    ok = mnesia:delete({rabbit_queue, QueueName}),
    ok = mnesia:delete({rabbit_durable_queue, QueueName}),
    %% we want to execute some things, as decided by rabbit_exchange,
    %% after the transaction.
    rabbit_binding:remove_for_destination(QueueName).

internal_delete(QueueName) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () ->
              case mnesia:wread({rabbit_queue, QueueName}) of
                  []  -> rabbit_misc:const({error, not_found});
                  [_] -> Deletions = internal_delete1(QueueName),
                         fun (Tx) -> ok = rabbit_binding:process_deletions(
                                            Deletions, Tx)
                         end
              end
      end).

maybe_run_queue_via_backing_queue(QPid, Fun) ->
    gen_server2:call(QPid, {maybe_run_queue_via_backing_queue, Fun}, infinity).

maybe_run_queue_via_backing_queue_async(QPid, Fun) ->
    gen_server2:cast(QPid, {maybe_run_queue_via_backing_queue, Fun}).

sync_timeout(QPid) ->
    gen_server2:cast(QPid, sync_timeout).

update_ram_duration(QPid) ->
    gen_server2:cast(QPid, update_ram_duration).

set_ram_duration_target(QPid, Duration) ->
    gen_server2:cast(QPid, {set_ram_duration_target, Duration}).

set_maximum_since_use(QPid, Age) ->
    gen_server2:cast(QPid, {set_maximum_since_use, Age}).

maybe_expire(QPid) ->
    gen_server2:cast(QPid, maybe_expire).

drop_expired(QPid) ->
    gen_server2:cast(QPid, drop_expired).

on_node_down(Node) ->
    rabbit_misc:execute_mnesia_transaction(
      fun () -> qlc:e(qlc:q([delete_queue(QueueName) ||
                                #amqqueue{name = QueueName, pid = Pid}
                                    <- mnesia:table(rabbit_queue),
                                node(Pid) == Node]))
      end,
      fun (Deletions, Tx) ->
              rabbit_binding:process_deletions(
                lists:foldl(fun rabbit_binding:combine_deletions/2,
                            rabbit_binding:new_deletions(),
                            Deletions),
                Tx)
      end).

delete_queue(QueueName) ->
    ok = mnesia:delete({rabbit_queue, QueueName}),
    rabbit_binding:remove_transient_for_destination(QueueName).

pseudo_queue(QueueName, Pid) ->
    #amqqueue{name = QueueName,
              durable = false,
              auto_delete = false,
              arguments = [],
              pid = Pid}.

safe_delegate_call_ok(F, Pids) ->
    case delegate:invoke(Pids, fun (Pid) ->
                                       rabbit_misc:with_exit_handler(
                                         fun () -> ok end,
                                         fun () -> F(Pid) end)
                               end) of
        {_,  []} -> ok;
        {_, Bad} -> {error, Bad}
    end.

delegate_call(Pid, Msg, Timeout) ->
    delegate:invoke(Pid, fun (P) -> gen_server2:call(P, Msg, Timeout) end).

delegate_cast(Pid, Msg) ->
    delegate:invoke_no_result(Pid, fun (P) -> gen_server2:cast(P, Msg) end).
