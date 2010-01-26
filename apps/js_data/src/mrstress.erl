-module(mrstress).

-compile([export_all]).

s(InputSize) ->
    populate(InputSize),
    mrstress:stress(config(javascript, 1, 1, InputSize)).

v(InputSize) ->
    populate(InputSize),
    mrstress:stress(config(javascript, 200, 250, InputSize)).

populate(InputSize) ->
    {ok, Client} = riak:client_connect('riak@127.0.0.1'),
    lists:foreach(fun({Bucket, Key}) ->
                          Obj = riak_object:new(Bucket, Key, <<"1">>),
                          ok = Client:put(Obj, 1) end, generate_inputs(<<"stress">>, InputSize)).

config(Lang, Clients, Count, KeyCount) ->
    [{lang, Lang}, {clients, Clients}, {count, Count}, {keys, KeyCount}].

stress(Config) ->
    Lang = proplists:get_value(lang, Config),
    Count = proplists:get_value(count, Config, 100),
    Clients = proplists:get_value(clients, Config, 1),
    KeyCount = proplists:get_value(keys, Config, 10),
    Start = erlang:now(),
    start_test(Lang, Count, Clients, KeyCount),
    case wait_for_end(Clients) of
        ok ->
            End = erlang:now(),
            Elapsed = timer:now_diff(End, Start),
            {Elapsed, (Elapsed / Clients) / Count};
        Error ->
            Error
    end.

wait_for_end(0) ->
    ok;
wait_for_end(Clients) ->
    receive
        done ->
            wait_for_end(Clients - 1)
    after 300000 ->
            {error, run_timeout}
    end.

start_test(_Lang, _Count, 0, _) ->
    ok;
start_test(Lang, Count, Clients, KeyCount) ->
    Owner = self(),
    spawn(fun() -> {ok, Client} = riak:client_connect('riak@127.0.0.1'),
                   stress(Lang, Count, Client, Owner, KeyCount) end),
    start_test(Lang, Count, Clients - 1, KeyCount).

stress(_Lang, 0, _Client, Owner, _) ->
    Owner ! done,
    ok;
stress(javascript, Count, Client, Owner, KeyCount) ->
    M = <<"function(v, _, _) { var value = v[\"values\"][0][\"data\"]; return [parseInt(value)]; }">>,
    %R = <<"function(v, _) { var sum = 0; v.forEach(function(x) { sum = sum + x; }); return [sum]; }">>,
    %R1 = <<"function(v, _) { return v; }">>,
    %case Client:mapred(?INPUTS, [{map, {jsanon, M}, none, false},
    %                             {reduce, {jsanon, {<<"stress">>, <<"test10">>}}, none, false},
    %                             {reduce, {jsanon, R1}, none, true}]) of
    case Client:mapred(generate_inputs(<<"stress">>, KeyCount), [{map, {jsanon, M}, none, false},
                                 {reduce, {jsfun, <<"Riak.reduceSum">>}, none, true}]) of
        {ok, [10]} ->
            stress(javascript, Count - 1, Client, Owner, KeyCount);
        {ok, WTF} ->
            io:format("Bailing!!!! WTF: ~p~n", WTF),
            stress(javascript, 0, Client, Owner, KeyCount);
        Error ->
            io:format("(~p): ~p~n", [self(), Error]),
            stress(javascript, 0, Client, Owner, KeyCount)
    end;

stress(erlang, Count, Client, Owner, KeyCount) ->
    M = fun(Obj, _, _) ->
                Value = riak_object:get_value(Obj),
                [list_to_integer(binary_to_list(Value))] end,
    R = fun(Values, _) -> lists:sum(Values) / length(Values) end,
    case Client:mapred(generate_inputs(<<"stress">>, KeyCount), [{map, {qfun, M}, none, false},
                                                                 {reduce, {qfun, R}, none, true}]) of
        {ok, _Result} ->
            stress(erlang, Count - 1, Client, Owner, KeyCount);
        Error ->
            io:format("(~p): ~p~n", [self(), Error]),
            stress(erlang, Count, Client, Owner, KeyCount)
    end.

generate_inputs(Bucket, Size) ->
    [{Bucket, list_to_binary("test" ++ integer_to_list(X))} || X <- lists:seq(1, Size)].
