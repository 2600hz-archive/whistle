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

-type(fetch_result(Ack) ::
        ('empty' |
         %% Message,                  IsDelivered, AckTag, Remaining_Len
         {rabbit_types:basic_message(), boolean(), Ack, non_neg_integer()})).
-type(is_durable() :: boolean()).
-type(attempt_recovery() :: boolean()).
-type(purged_msg_count() :: non_neg_integer()).
-type(confirm_required() :: boolean()).
-type(message_properties_transformer() ::
        fun ((rabbit_types:message_properties())
             -> rabbit_types:message_properties())).

-spec(start/1 :: ([rabbit_amqqueue:name()]) -> 'ok').
-spec(stop/0 :: () -> 'ok').
-spec(init/3 :: (rabbit_amqqueue:name(), is_durable(), attempt_recovery()) ->
                     state()).
-spec(terminate/1 :: (state()) -> state()).
-spec(delete_and_terminate/1 :: (state()) -> state()).
-spec(purge/1 :: (state()) -> {purged_msg_count(), state()}).
-spec(publish/3 :: (rabbit_types:basic_message(),
                    rabbit_types:message_properties(), state()) -> state()).
-spec(publish_delivered/4 :: (true, rabbit_types:basic_message(),
                              rabbit_types:message_properties(), state())
                             -> {ack(), state()};
                             (false, rabbit_types:basic_message(),
                              rabbit_types:message_properties(), state())
                             -> {undefined, state()}).
-spec(dropwhile/2 ::
        (fun ((rabbit_types:message_properties()) -> boolean()), state())
        -> state()).
-spec(fetch/2 :: (true,  state()) -> {fetch_result(ack()), state()};
                 (false, state()) -> {fetch_result(undefined), state()}).
-spec(ack/2 :: ([ack()], state()) -> state()).
-spec(tx_publish/4 :: (rabbit_types:txn(), rabbit_types:basic_message(),
                       rabbit_types:message_properties(), state()) -> state()).
-spec(tx_ack/3 :: (rabbit_types:txn(), [ack()], state()) -> state()).
-spec(tx_rollback/2 :: (rabbit_types:txn(), state()) -> {[ack()], state()}).
-spec(tx_commit/4 ::
        (rabbit_types:txn(), fun (() -> any()),
         message_properties_transformer(), state()) -> {[ack()], state()}).
-spec(requeue/3 :: ([ack()], message_properties_transformer(), state())
                   -> state()).
-spec(len/1 :: (state()) -> non_neg_integer()).
-spec(is_empty/1 :: (state()) -> boolean()).
-spec(set_ram_duration_target/2 ::
      (('undefined' | 'infinity' | number()), state()) -> state()).
-spec(ram_duration/1 :: (state()) -> {number(), state()}).
-spec(needs_idle_timeout/1 :: (state()) -> boolean()).
-spec(idle_timeout/1 :: (state()) -> state()).
-spec(handle_pre_hibernate/1 :: (state()) -> state()).
-spec(status/1 :: (state()) -> [{atom(), any()}]).
