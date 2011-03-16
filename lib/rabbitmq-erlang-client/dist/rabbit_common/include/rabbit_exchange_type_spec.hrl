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

-ifdef(use_specs).

-spec(description/0 :: () -> [{atom(), any()}]).
-spec(route/2 :: (rabbit_types:exchange(), rabbit_types:delivery())
                 -> rabbit_router:match_result()).
-spec(validate/1 :: (rabbit_types:exchange()) -> 'ok').
-spec(create/2 :: (boolean(), rabbit_types:exchange()) -> 'ok').
-spec(recover/2 :: (rabbit_types:exchange(),
                    [rabbit_types:binding()]) -> 'ok').
-spec(delete/3 :: (boolean(), rabbit_types:exchange(),
                   [rabbit_types:binding()]) -> 'ok').
-spec(add_binding/3 :: (boolean(), rabbit_types:exchange(),
                        rabbit_types:binding()) -> 'ok').
-spec(remove_bindings/3 :: (boolean(), rabbit_types:exchange(),
                            [rabbit_types:binding()]) -> 'ok').
-spec(assert_args_equivalence/2 ::
        (rabbit_types:exchange(), rabbit_framing:amqp_table())
        -> 'ok' | rabbit_types:connection_exit()).

-endif.
