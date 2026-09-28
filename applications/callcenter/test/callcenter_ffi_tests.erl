%% `callcenter_ffi''s publishing for the call publishers
%% (`callcenter/call/publishers'): a `kapi' publisher called by name from the
%% calling process -- not handed to `kz_amqp_worker' -- so that what it
%% publishes is on the calling process's channel, and what the definition
%% refuses or the platform lacks comes back as the error `kazoo/amqp' would
%% have given.
%%
%% `platform_fakes' records every publish against the process that made it,
%% which is what says the message went out from here.
-module(callcenter_ffi_tests).

-include_lib("eunit/include/eunit.hrl").

-import(callcenter_messages, [full/1]).

with_platform(Tests) ->
    {'setup', fun platform_fakes:start/0, fun platform_fakes:stop/1, Tests}.

json(Props) -> iolist_to_binary(json:encode(maps:from_list(Props))).

publish_here_test_() ->
    with_platform(
      [{"a member_continue goes out at the controller queue from the calling process, not the worker pool"
       ,fun() ->
                platform_fakes:clear(),
                ?assertEqual({'ok', 'nil'}
                            ,callcenter_ffi:publish_here_to(<<"pid://<0.1.0>/cf">>
                                                           ,<<"callcenter">>
                                                           ,<<"member_continue">>
                                                           ,json(full(<<"member_continue">>))
                                                           )
                            ),
                ?assertEqual([<<"pid://<0.1.0>/cf">>], platform_fakes:targeted()),
                ?assertEqual([], platform_fakes:calls('kz_amqp_worker'))
        end}
      ,{"a message its definition refuses is an error, and nothing goes out"
       ,fun() ->
                platform_fakes:clear(),
                NoBranch = lists:keydelete(<<"Branch">>, 1, full(<<"member_continue">>)),
                ?assertMatch({'error', _}
                            ,callcenter_ffi:publish_here_to(<<"q">>
                                                           ,<<"callcenter">>
                                                           ,<<"member_continue">>
                                                           ,json(NoBranch)
                                                           )
                            ),
                ?assertEqual([], platform_fakes:calls('kz_amqp_util'))
        end}
      ,{"a publisher the module does not have is named as such"
       ,fun() ->
                ?assertEqual({'error', <<"no_such_publisher">>}
                            ,callcenter_ffi:publish_here(<<"callcenter">>, <<"no_such_message">>, <<"{}">>)
                            ),
                %% `publish_member_continue' takes a queue: there is none of
                %% arity one.
                ?assertEqual({'error', <<"no_such_publisher">>}
                            ,callcenter_ffi:publish_here(<<"callcenter">>, <<"member_continue">>, <<"{}">>)
                            )
        end}
      ,{"a module the platform does not have is unavailable"
       ,?_assertEqual({'error', <<"unavailable">>}
                     ,callcenter_ffi:publish_here(<<"callcenter_no_such_family">>, <<"thing">>, <<"{}">>)
                     )}
      ]).

%% Outside a release there is nothing to publish with, as `kazoo/amqp' says.
without_the_platform_test() ->
    ?assertEqual({'error', <<"unavailable">>}
                ,callcenter_ffi:publish_here_to(<<"q">>
                                               ,<<"callcenter">>
                                               ,<<"member_continue">>
                                               ,json(full(<<"member_continue">>))
                                               )
                ).

run_guarded_test_() ->
    [?_assertEqual({'ok', 'nil'}, callcenter_ffi:run_guarded(fun() -> 'anything' end))
    ,?_assertMatch({'error', <<"error: ", _/binary>>}
                  ,callcenter_ffi:run_guarded(fun() -> erlang:error('boom') end)
                  )
    ,?_assertMatch({'error', <<"exit: ", _/binary>>}
                  ,callcenter_ffi:run_guarded(fun() -> exit('gone') end)
                  )
    ,?_assertMatch({'error', <<"throw: ", _/binary>>}
                  ,callcenter_ffi:run_guarded(fun() -> throw('up') end)
                  )
    ].
