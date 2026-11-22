%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2025, 2600Hz
%%% (C) 2026, Vonix LLC
%%% @doc Handle CNAM provisioning against the Telnyx API v2.
%%%
%%% v2 folds both halves of CNAM into one `PATCH /phone_numbers/{id}/voice'
%%% call: inbound lookup is `caller_id_name_enabled', and the outbound listing
%%% lives under `cnam_listing'. Both are addressed by Telnyx's opaque number
%%% id, not by the E.164 number the v1 module used.
%%% @end
%%%-----------------------------------------------------------------------------
-module(knm_telnyx2_cnam).
-behaviour(knm_gen_provider).

-export([save/1]).
-export([delete/1]).

-include("knm.hrl").

%% "Must be alphanumeric characters or spaces with a maximum length of 15."
-define(CNAM_MAX_LENGTH, 15).

%%------------------------------------------------------------------------------
%% @doc This function is called each time a number is saved, and will
%% produce notifications if the cnam object changes
%% @end
%%------------------------------------------------------------------------------
-spec save(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
save(PN) ->
    State = knm_phone_number:state(PN),
    save(PN, State).

-spec save(knm_phone_number:pn_record(), kz_term:ne_binary()) -> knm_phone_number:pn_record().
save(PN, ?NUMBER_STATE_RESERVED) ->
    handle(PN);
save(PN, ?NUMBER_STATE_IN_SERVICE) ->
    handle(PN);
save(PN, ?NUMBER_STATE_PORT_IN) ->
    handle(PN);
save(PN, _State) ->
    PN.

%%------------------------------------------------------------------------------
%% @doc This function is called each time a number is deleted
%% @end
%%------------------------------------------------------------------------------
-spec delete(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
delete(PN) ->
    _ = toggle_inbound(PN, 'false'),
    knm_providers:deactivate_features(PN
                                     ,[?FEATURE_CNAM_INBOUND
                                      ,?FEATURE_CNAM_OUTBOUND
                                      ,?FEATURE_CNAM
                                      ]
                                     ).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec handle(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
handle(PN) ->
    support_depreciated_cnam(
      handle_inbound_cnam(
        handle_outbound_cnam(
          PN
         )
       )
     ).

-spec handle_outbound_cnam(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
handle_outbound_cnam(PN) ->
    IsDryRun = knm_phone_number:dry_run(PN),
    Doc = knm_phone_number:doc(PN),
    Feature = knm_phone_number:feature(PN, ?FEATURE_CNAM_OUTBOUND),
    CurrentCNAM = kz_json:get_ne_value(?CNAM_DISPLAY_NAME, Feature),
    case kz_json:get_ne_value([?FEATURE_CNAM, ?CNAM_DISPLAY_NAME], Doc) of
        'undefined' ->
            knm_providers:deactivate_feature(PN, ?FEATURE_CNAM_OUTBOUND);
        CurrentCNAM -> PN;
        NewCNAM when IsDryRun ->
            lager:debug("dry run: cnam display name changed to ~s", [NewCNAM]),
            knm_providers:activate_feature(PN, {?FEATURE_CNAM_OUTBOUND, NewCNAM});
        NewCNAM ->
            FeatureData = kz_json:from_list([{?CNAM_DISPLAY_NAME, NewCNAM}]),
            PN1 = knm_providers:activate_feature(PN, {?FEATURE_CNAM_OUTBOUND, FeatureData}),
            _ = set_outbound(PN1, NewCNAM),
            _ = publish_cnam_update(PN1),
            PN1
    end.

-spec handle_inbound_cnam(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
handle_inbound_cnam(PN) ->
    CurrentInboundCNAM = kz_json:is_true(?CNAM_INBOUND_LOOKUP
                                        ,knm_phone_number:feature(PN, ?FEATURE_CNAM_INBOUND)),
    InboundCNAM = kz_json:is_true([?FEATURE_CNAM, ?CNAM_INBOUND_LOOKUP]
                                 ,knm_phone_number:doc(PN)
                                 ),
    NotChanged = CurrentInboundCNAM =:= InboundCNAM,
    case InboundCNAM of
        'false' when NotChanged -> PN;
        'false' ->
            _ = toggle_inbound(PN, 'false'),
            knm_providers:deactivate_features(PN, [?FEATURE_CNAM_INBOUND
                                                  ,?CNAM_INBOUND_LOOKUP
                                                  ]);
        'true' when NotChanged -> PN;
        'true' ->
            _ = toggle_inbound(PN, 'true'),
            FeatureData = kz_json:from_list([{?CNAM_INBOUND_LOOKUP, 'true'}]),
            knm_providers:activate_feature(PN, {?FEATURE_CNAM_INBOUND, FeatureData})
    end.

-spec support_depreciated_cnam(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
support_depreciated_cnam(PN) ->
    knm_providers:deactivate_feature(PN, ?FEATURE_CNAM).

-spec toggle_inbound(knm_phone_number:pn_record(), boolean()) -> 'ok'.
toggle_inbound(PN, ShouldEnable) ->
    case knm_phone_number:dry_run(PN) of
        'true' -> 'ok';
        'false' ->
            Key = <<"caller_id_name_enabled">>,
            Body = kz_json:from_list([{Key, ShouldEnable}]),
            Rep = voice_settings(PN, Body),
            ShouldEnable = kz_json:is_true([<<"data">>, Key], Rep),
            'ok'
    end.

-spec set_outbound(knm_phone_number:pn_record(), kz_term:ne_binary()) -> 'ok'.
set_outbound(PN, NewCNAM) ->
    Details = cleanse(NewCNAM),
    Body = kz_json:from_list(
             [{<<"cnam_listing">>
              ,kz_json:from_list([{<<"cnam_listing_details">>, Details}
                                 ,{<<"cnam_listing_enabled">>, 'true'}
                                 ])
              }
             ]),
    Rep = voice_settings(PN, Body),
    Details = kz_json:get_ne_binary_value([<<"data">>, <<"cnam_listing">>, <<"cnam_listing_details">>], Rep),
    'ok'.

-spec voice_settings(knm_phone_number:pn_record(), kz_json:object()) -> kz_json:object().
voice_settings(PN, Body) ->
    Id = knm_telnyx2_util:number_id(PN),
    knm_telnyx2_util:req('patch', ["phone_numbers", kz_term:to_list(Id), "voice"], Body).

%%------------------------------------------------------------------------------
%% @doc Telnyx rejects a listing that is not alphanumeric-or-space, or longer
%% than 15 characters, so trim it here rather than fail the whole save.
%% @end
%%------------------------------------------------------------------------------
-spec cleanse(kz_term:ne_binary()) -> kz_term:ne_binary().
cleanse(CNAM) ->
    Alnum = << <<C>> || <<C>> <= CNAM, is_alnum_or_space(C)>>,
    kz_binary:truncate(Alnum, ?CNAM_MAX_LENGTH).

-spec is_alnum_or_space(char()) -> boolean().
is_alnum_or_space(C) when $0 =< C, C =< $9 -> 'true';
is_alnum_or_space(C) when $A =< C, C =< $Z -> 'true';
is_alnum_or_space(C) when $a =< C, C =< $z -> 'true';
is_alnum_or_space(C) -> $\s =:= C.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec publish_cnam_update(knm_phone_number:pn_record()) -> 'ok'.
-ifndef(TEST).
publish_cnam_update(PN) ->
    Feature = knm_phone_number:feature(PN, ?FEATURE_CNAM),
    Notify = [{<<"Account-ID">>, knm_phone_number:assigned_to(PN)}
             ,{<<"Number-State">>, knm_phone_number:state(PN)}
             ,{<<"Local-Number">>, knm_phone_number:module_name(PN) =:= ?CARRIER_LOCAL}
             ,{<<"Number">>, knm_util:pretty_print(knm_phone_number:number(PN))}
             ,{<<"Acquired-For">>, knm_phone_number:auth_by(PN)}
             ,{<<"Cnam">>, case Feature of 'undefined' -> kz_json:new(); _ -> Feature end}
              | kz_api:default_headers(?APP_VERSION, ?APP_NAME)
             ],
    kapps_notify_publisher:cast(Notify, fun kapi_notifications:publish_cnam_request/1).
-else.
publish_cnam_update(_PN) -> 'ok'.
-endif.

%%% End of Module
