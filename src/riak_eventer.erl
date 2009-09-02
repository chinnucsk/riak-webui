%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at

%%   http://www.apache.org/licenses/LICENSE-2.0

%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.    

-module(riak_eventer).
-behaviour(gen_server2).
-export([start_link/0,start_link/1,stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([notify/1,notify/3,eventer_config/1,do_eventer/1]).

%% @private
start_link() -> gen_server2:start_link({local, ?MODULE}, ?MODULE, [], []).
start_link(test) -> % when started this way, run a mock server (nop)
    gen_server2:start_link({local, ?MODULE}, ?MODULE, [test], []).

%% @private
init([]) -> {ok, stateless_server};
init([test]) -> {ok, test}.

notify(Event) ->
    gen_server2:cast(riak_local_logger, {event, Event}),
    gen_server2:cast(?MODULE, {event, Event}).

notify(Module, EventName, EventDetail) ->
    notify({Module, EventName, node(), EventDetail}).

%% @private (only used for test instances)
stop() -> gen_server2:cast(?MODULE, stop).

%% @private
handle_cast(stop, State) -> {stop,normal,State};

handle_cast({event, _Event}, test) -> {noreply,test};
handle_cast({event, Event}, State) ->
    {ok, Ring} = riak_ring_manager:get_my_ring(),    %%%% TEST EVENTS!
    Eventers = get_eventers(Ring),
    [gen_event:notify({riak_event,Node},Event) || Node <- Eventers],
    {noreply, State}.
    
eventer_config([Cluster, CookieStr]) ->
    RipConf = [{no_config, true}, {cluster_name, Cluster},
       {riak_cookie, list_to_atom(CookieStr)}, {ring_state_dir, "<nostore>"},
       {ring_creation_size, 12}, {gossip_interval,1000000},
       {wants_claim_fun, {riak_claim, never_wants_claim}},
       {riak_web_ip, "undefined"},
       {doorbell_port, 7000 + random:uniform(1000)},
       {storage_backend, undefined}],
    application:stop(sasl),
    application:unload(sasl),
    ok = application:load({application,sasl,[{errlog_type,error}]}),
    ok = application:start(sasl),
    [application:set_env(riak,K,V) || {K,V} <- RipConf].

do_eventer([IP, PortStr, HandlerName, HandlerArg]) ->
    riak_startup:join_cluster([IP, PortStr]),
    timer:sleep(random:uniform(1000)), % let some gossip happen
    riak_event_guard:add_handler(list_to_atom(HandlerName), HandlerArg),
    ok.

get_eventers(Ring) ->
    case riak_ring:get_meta(eventers, Ring) of
        undefined -> [];
        {ok, X} -> sets:to_list(X)
    end.        

handle_info(_Info, State) -> {noreply, State}.

%% @private
terminate(_Reason, _State) -> ok.

%% @private
code_change(_OldVsn, State, _Extra) ->  {ok, State}.

%% @private
handle_call(_, _From, State) -> {reply, no_call_support, State}.
