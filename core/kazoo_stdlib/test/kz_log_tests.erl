%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2025, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_log_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kazoo_stdlib/include/kz_log.hrl").

%% Just to please coverage :)
log_test_() ->
    ST = try throw('just_for_fun')
         catch
             ?STACKTRACE(_E, _R, Stack)
             Stack
             end,
    [?_assertEqual('ok', kz_log:log_stacktrace(ST))].

put_callid_test_() ->
    ApiCallId = [{<<"Call-ID">>, <<"bla">>}],
    [?_assertEqual(<<"bla">>, begin kz_log:put_callid(<<"bla">>), kz_log:get_callid() end)
    ,?_assertEqual('bla', begin kz_log:put_callid('bla'), kz_log:get_callid() end)
    ,?_assertEqual(<<"bla">>, begin kz_log:put_callid(ApiCallId), kz_log:get_callid() end)
    ,?_assertEqual(<<"bla">>, begin kz_log:put_callid(kz_json:from_list(ApiCallId)), kz_log:get_callid() end)
    ,?_assert(is_integer(begin kz_process:set_startup(), kz_process:startup() end))
    ].

log_redacted_test_() ->
    User = kz_binary:rand_hex(5),
    Pass = kz_binary:rand_hex(5),
    URL = <<"server.tld/some/path">>,

    %% test URL BasicAuth cred stripping
    [?_assertEqual(<<"http://", URL/binary>>, kz_log:redactor(<<"http://", URL/binary>>))
    ,?_assertEqual(<<"https://", URL/binary>>, kz_log:redactor(<<"https://", URL/binary>>))

    ,?_assertEqual(<<"http://", URL/binary>>, kz_log:redactor(<<"http://", User/binary, ":", Pass/binary, "@", URL/binary>>))
    ,?_assertEqual(<<"https://", URL/binary>>, kz_log:redactor(<<"https://", User/binary, ":", Pass/binary, "@", URL/binary>>))

    ,?_assertEqual(<<"amqp://", URL/binary>>, kz_log:redactor(<<"amqp://", User/binary, ":", Pass/binary, "@", URL/binary>>))
    ,?_assertEqual(<<"amqps://", URL/binary>>, kz_log:redactor(<<"amqps://", User/binary, ":", Pass/binary, "@", URL/binary>>))

     %% redact JSON password field
    ,?_assertEqual(<<"{\"password\":\"***REDACTED***\",\"foo\":\"bar\"}">>
                  ,kz_log:redactor(<<"{\"password\":\"", Pass/binary, "\",\"foo\":\"bar\"}">>)
                  )
     %% spaces preserved in JSON
    ,?_assertEqual(<<"{\"password\" : \"***REDACTED***\" , \"foo\" : \"bar\"}">>
                  ,kz_log:redactor(<<"{\"password\" : \"", Pass/binary, "\" , \"foo\" : \"bar\"}">>)
                  )
    ].

-define(REDACTED, <<"***REDACTED***">>).

%% The settings kazoo_config_init logs as it starts: config.ini's sections.
redact_term_config_ini_test_() ->
    AppEnv = [{<<"amqp">>, [{<<"uri">>, <<"amqp://offhook:amqp-pass-1@lavinmq.offhook.svc:5672">>}
                           ,{<<"pool_size">>, 20}
                           ]}
             ,{<<"zone">>, [{<<"name">>, 'local'}
                           ,{<<"amqp_uri">>, [<<"amqp://guest:amqp-pass-2@a:5672">>
                                             ,<<"amqp://guest:amqp-pass-3@b:5672">>
                                             ]}
                           ]}
             ,{<<"data">>, [{<<"config">>, <<"kazoo_sql">>}]}
             ,{<<"kazoo_sql">>, [{<<"hosts">>, <<"yb-tserver-0,yb-tserver-1">>}
                                ,{<<"port">>, 5433}
                                ,{<<"username">>, <<"yugabyte">>}
                                ,{<<"password">>, <<"db-pass-4">>}
                                ,{<<"topology_keys">>, <<"gcp.us-east1.us-east1-b">>}
                                ]}
             ,{<<"kazoo_apps">>, [{<<"cookie">>, 'cookie-5'}]}
             ,{<<"log">>, [{<<"console">>, <<"info">>}]}
             ],
    Expected = [{<<"amqp">>, [{<<"uri">>, <<"amqp://offhook:***REDACTED***@lavinmq.offhook.svc:5672">>}
                             ,{<<"pool_size">>, 20}
                             ]}
               ,{<<"zone">>, [{<<"name">>, 'local'}
                             ,{<<"amqp_uri">>, [<<"amqp://guest:***REDACTED***@a:5672">>
                                               ,<<"amqp://guest:***REDACTED***@b:5672">>
                                               ]}
                             ]}
               ,{<<"data">>, [{<<"config">>, <<"kazoo_sql">>}]}
               ,{<<"kazoo_sql">>, [{<<"hosts">>, <<"yb-tserver-0,yb-tserver-1">>}
                                  ,{<<"port">>, 5433}
                                  ,{<<"username">>, <<"yugabyte">>}
                                  ,{<<"password">>, ?REDACTED}
                                  ,{<<"topology_keys">>, <<"gcp.us-east1.us-east1-b">>}
                                  ]}
               ,{<<"kazoo_apps">>, [{<<"cookie">>, ?REDACTED}]}
               ,{<<"log">>, [{<<"console">>, <<"info">>}]}
               ],
    [?_assertEqual(Expected, kz_log:redact_term(AppEnv))
    ,?_assertEqual([], leaked(AppEnv))
    ].

%% A #data_connection{} as kz_dataconnection logs it: kz_dataconfig's
%% connection map, and a CouchDB server whose URL and options carry the
%% password too.
redact_term_data_connection_test_() ->
    Pid = self(),
    Props = #{driver => 'kazoo_couch'
             ,tag => <<"local">>
             ,ip => <<"couchdb">>
             ,port => 5984
             ,username => <<"admin">>
             ,password => <<"db-pass-6">>
             ,settings => #{credentials => #{username => <<"admin">>
                                            ,password => <<"db-pass-7">>
                                            }
                           ,pool => #{name => 'kazoo_couch', size => 10}
                           }
             ,connect_options => [{'keepalive', 'true'}]
             },
    Server = {'server'
             ,"http://admin:db-pass-8@couchdb:5984"
             ,[{'connection_map', #{username => <<"admin">>, password => <<"db-pass-9">>}}
              ,{'basic_auth', {"admin", "db-pass-10"}}
              ,{'pool_name', 'kazoo_couch'}
              ]
             },
    Connection = {'data_connection', {1727827200, <<"a1b2c3d4">>}, 'kazoo_couch'
                 ,Props, Server, 'true', 'true', <<"local">>, Pid
                 },
    ExpectedProps = Props#{password => ?REDACTED
                          ,settings => #{credentials => ?REDACTED
                                        ,pool => #{name => 'kazoo_couch', size => 10}
                                        }
                          },
    ExpectedServer = {'server'
                     ,"http://admin:***REDACTED***@couchdb:5984"
                     ,[{'connection_map', #{username => <<"admin">>, password => ?REDACTED}}
                      ,{'basic_auth', ?REDACTED}
                      ,{'pool_name', 'kazoo_couch'}
                      ]
                     },
    [?_assertEqual({'data_connection', {1727827200, <<"a1b2c3d4">>}, 'kazoo_couch'
                   ,ExpectedProps, ExpectedServer, 'true', 'true', <<"local">>, Pid
                   }
                  ,kz_log:redact_term(Connection)
                  )
    ,?_assertEqual([], leaked(Connection))
    ,?_assertEqual(ExpectedProps, kz_log:redact_term(Props))
    ].

%% A storage plan as kzs_plan logs it: attachment handlers keep everything
%% but their credentials.
redact_term_storage_plan_test_() ->
    Plan = #{<<"plan">> =>
                 #{<<"account">> =>
                       #{<<"types">> =>
                             #{<<"call_recording">> =>
                                   #{<<"attachments">> => #{<<"handler">> => <<"s3-1">>
                                                           ,<<"params">> => #{<<"folder_path">> => <<"recordings">>}
                                                           }}}}}
            ,<<"attachments">> =>
                 #{<<"s3-1">> => #{<<"handler">> => <<"s3">>
                                  ,<<"settings">> => #{<<"bucket">> => <<"recordings">>
                                                      ,<<"host">> => <<"storage.googleapis.com">>
                                                      ,<<"scheme">> => <<"https">>
                                                      ,<<"key">> => <<"hmac-key-11">>
                                                      ,<<"secret">> => <<"hmac-secret-12">>
                                                      }
                                  }
                  ,<<"gdrive-1">> => #{<<"handler">> => <<"google_drive">>
                                      ,<<"settings">> => #{<<"oauth_doc_id">> => <<"doc-1">>
                                                          ,<<"folder_id">> => <<"folder-1">>
                                                          }
                                      }
                  ,<<"http-1">> => #{<<"handler">> => <<"http">>
                                    ,<<"settings">> => #{<<"url">> => <<"https://store:http-pass-13@files.example.com/put">>
                                                        ,<<"verb">> => <<"put">>
                                                        }
                                    }
                  }
            },
    #{<<"attachments">> := Attachments} = Plan,
    #{<<"s3-1">> := #{<<"settings">> := S3}
     ,<<"http-1">> := #{<<"settings">> := HTTP}=HTTPHandler
     } = Attachments,
    Expected = Plan#{<<"attachments">> =>
                         Attachments#{<<"s3-1">> => #{<<"handler">> => <<"s3">>
                                                     ,<<"settings">> => S3#{<<"key">> => ?REDACTED
                                                                           ,<<"secret">> => ?REDACTED
                                                                           }
                                                     }
                                     ,<<"http-1">> => HTTPHandler#{<<"settings">> => HTTP#{<<"url">> => <<"https://store:***REDACTED***@files.example.com/put">>}}
                                     }
                    },
    [?_assertEqual(Expected, kz_log:redact_term(Plan))
    ,?_assertEqual([], leaked(Plan))
    ].

redact_term_kz_json_test_() ->
    JObj = kz_json:from_list([{<<"realm">>, <<"lab.invalid">>}
                             ,{<<"password">>, <<"sip-pass-14">>}
                             ]),
    [?_assertEqual(kz_json:from_list([{<<"realm">>, <<"lab.invalid">>}
                                     ,{<<"password">>, ?REDACTED}
                                     ])
                  ,kz_log:redact_term(JObj)
                  )
    ,?_assertEqual([], leaked(JObj))
    ].

%% Which keys name a credential. Each is shown with its verdict so a failure
%% says which key it was.
redact_term_credential_keys_test_() ->
    Credentials = [<<"password">>, 'password', "password", <<"Password">>
                  ,<<"db_password">>, <<"passwd">>, <<"pass">>, <<"pwd">>
                  ,<<"passphrase">>, <<"secret">>, <<"client_secret">>
                  ,<<"secret_access_key">>, <<"key">>, 'key', <<"api_key">>
                  ,<<"apiKey">>, <<"apikey">>, <<"accessKey">>, <<"private_key">>
                  ,<<"privateKey">>, <<"token">>, <<"auth_token">>
                  ,<<"refresh_token">>, <<"X-Auth-Token">>, 'basic_auth'
                  ,<<"Authorization">>, <<"credentials">>, <<"creds">>
                  ,<<"cookie">>, 'cookie', <<"pin">>
                  ],
    NotCredentials = [<<"username">>, 'user', <<"host">>, <<"url">>
                     ,<<"keepalive">>, <<"topology_keys">>, <<"oauth_doc_id">>
                     ,<<"passive">>, <<"ping">>, <<"monkey">>, <<"author">>
                     ,<<"bucket">>, 'undefined', 42, {<<"password">>}, <<255, 254>>
                     ],
    [?_assertEqual({Key, 'true'}, {Key, is_redacted(Key)}) || Key <- Credentials]
        ++ [?_assertEqual({Key, 'false'}, {Key, is_redacted(Key)}) || Key <- NotCredentials].

%% An unset credential is shown as unset: it says nothing secret, and it is
%% often why a connection failed.
redact_term_empty_credential_test_() ->
    Empty = [{<<"password">>, 'undefined'}
            ,{<<"secret">>, 'null'}
            ,{<<"token">>, <<>>}
            ,{<<"key">>, []}
            ],
    [?_assertEqual(Empty, kz_log:redact_term(Empty))
    ,?_assertEqual(#{password => 'undefined'}, kz_log:redact_term(#{password => 'undefined'}))
    ].

redact_term_uri_test_() ->
    [?_assertEqual(<<"amqp://user:***REDACTED***@host:5672/vhost">>
                  ,kz_log:redact_term(<<"amqp://user:amqp-pass@host:5672/vhost">>)
                  )
    ,?_assertEqual("amqp://user:***REDACTED***@host:5672"
                  ,kz_log:redact_term("amqp://user:amqp-pass@host:5672")
                  )
    ,?_assertEqual(<<"postgresql://yugabyte:***REDACTED***@yb:5433/yugabyte?sslmode=require">>
                  ,kz_log:redact_term(<<"postgresql://yugabyte:db-pass@yb:5433/yugabyte?sslmode=require">>)
                  )
     %% only the first colon in the userinfo separates the user
    ,?_assertEqual(<<"amqp://user:***REDACTED***@host">>
                  ,kz_log:redact_term(<<"amqp://user:pa:ss@host">>)
                  )
    ,?_assertEqual(<<"from amqp://a:***REDACTED***@h1 to amqps://b:***REDACTED***@h2">>
                  ,kz_log:redact_term(<<"from amqp://a:pass-1@h1 to amqps://b:pass-2@h2">>)
                  )
    ,?_assertEqual("amqp://ü:***REDACTED***@hôst"
                  ,kz_log:redact_term("amqp://ü:pass@hôst")
                  )
     %% kz_couch_util does not percent-encode the password in its URL
    ,?_assertEqual(<<"http://admin:***REDACTED***@couchdb:5984">>
                  ,kz_log:redact_term(<<"http://admin:p@ss@couchdb:5984">>)
                  )
     %% an @ past the host is not the userinfo's
    ,?_assertEqual(<<"http://u:***REDACTED***@host:5984/db/doc@1">>
                  ,kz_log:redact_term(<<"http://u:pass@host:5984/db/doc@1">>)
                  )
    ,?_assertEqual(<<"http://u:***REDACTED***@host?email=a@b">>
                  ,kz_log:redact_term(<<"http://u:pass@host?email=a@b">>)
                  )
    ,?_assertEqual(<<"{\"uri\":\"amqp://u:***REDACTED***@h\",\"to\":\"x@y\"}">>
                  ,kz_log:redact_term(<<"{\"uri\":\"amqp://u:pass@h\",\"to\":\"x@y\"}">>)
                  )
     %% no password to remove
    ,?_assertEqual(<<"amqp://user@host:5672">>, kz_log:redact_term(<<"amqp://user@host:5672">>))
    ,?_assertEqual(<<"amqp://user:@host:5672">>, kz_log:redact_term(<<"amqp://user:@host:5672">>))
    ,?_assertEqual(<<"http://couchdb:5984/db/doc@1">>, kz_log:redact_term(<<"http://couchdb:5984/db/doc@1">>))
    ,?_assertEqual(<<"http://couchdb:5984?email=a@b">>, kz_log:redact_term(<<"http://couchdb:5984?email=a@b">>))
    ,?_assertEqual(<<"user:pass@host">>, kz_log:redact_term(<<"user:pass@host">>))
    ].

%% The #server{} kz_couch_util:connect/1 logs, and connection_info/1 logs
%% the URL of.
redact_term_couch_server_test_() ->
    ConnMap = #{host => "couchdb"
               ,port => 5984
               ,username => "admin"
               ,password => "db-pass-15"
               ,options => [{'pool_name', 'kazoo_couch'}]
               },
    Server = {'server'
             ,<<"http://admin:db-pass-16@couchdb:5984">>
             ,[{'connection_map', ConnMap}
              ,{'pool_name', 'kazoo_couch'}
              ,{'recv_timeout', 20000}
              ]
             },
    [?_assertEqual({'server'
                   ,<<"http://admin:***REDACTED***@couchdb:5984">>
                   ,[{'connection_map', ConnMap#{password => ?REDACTED}}
                    ,{'pool_name', 'kazoo_couch'}
                    ,{'recv_timeout', 20000}
                    ]
                   }
                  ,kz_log:redact_term(Server)
                  )
    ,?_assertEqual([], leaked(Server))
    ].

%% Terms with nothing to redact come back as they were, whatever their shape.
redact_term_unchanged_test_() ->
    Pid = self(),
    Ref = make_ref(),
    Fun = fun() -> 'ok' end,
    Terms = [[], {}, 42, 1.5, 'atom', <<>>, <<1:3>>, <<255, 0, 128>>
            ,Pid, Ref, Fun, "plain string", "héllo wörld ✓", [1, 2, 300000]
            ,['a' | 'b'], [{<<"host">>, 1} | 'tail'], {[]}, #{1 => 2}
            ,{<<255>>, <<"v">>}, {'ok', {'server', <<"http://couchdb:5984">>, []}}
            ,kz_json:from_list([{<<"realm">>, <<"lab.invalid">>}])
            ],
    [?_assertEqual(Term, kz_log:redact_term(Term)) || Term <- Terms].

redact_term_improper_list_test_() ->
    [?_assertEqual([{<<"password">>, ?REDACTED} | {<<"secret">>, ?REDACTED}]
                  ,kz_log:redact_term([{<<"password">>, <<"a">>} | {<<"secret">>, <<"b">>}])
                  )
    ].

is_redacted(Key) ->
    [{Key, ?REDACTED}] =:= kz_log:redact_term([{Key, <<"value">>}]).

%% The secrets in the fixtures above that a log line would print.
leaked(Term) ->
    Printed = unicode:characters_to_binary(io_lib:format("~p", [kz_log:redact_term(Term)])),
    Secrets = [<<"amqp-pass">>, <<"db-pass">>, <<"cookie-5">>, <<"hmac-key">>
              ,<<"hmac-secret">>, <<"http-pass">>, <<"sip-pass">>
              ],
    [Secret || Secret <- Secrets, 'nomatch' =/= binary:match(Printed, Secret)].
