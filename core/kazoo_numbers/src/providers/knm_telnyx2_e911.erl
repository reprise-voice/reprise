%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2025, 2600Hz
%%% (C) 2026, Vonix LLC
%%% @doc Handle e911 provisioning against the Telnyx API v2.
%%%
%%% The v2 shape differs from {@link knm_telnyx_e911} in three ways:
%%%
%%% <ul>
%%%   <li>addresses are created at `/addresses' (not `/e911_addresses') and
%%%       use `street_address'/`locality'/`administrative_area' rather than
%%%       `line_1'/`city'/`state';</li>
%%%   <li>a number is armed through
%%%       `POST /phone_numbers/{id}/actions/enable_emergency', addressed by
%%%       Telnyx's number id rather than the E.164 number;</li>
%%%   <li>`emergency_address_id' is required on that call even when disabling,
%%%       so the address must be released <em>after</em> the number is
%%%       disarmed, not before.</li>
%%% </ul>
%%% @end
%%%-----------------------------------------------------------------------------
-module(knm_telnyx2_e911).
-behaviour(knm_gen_provider).

-export([save/1]).
-export([delete/1]).

-include("knm.hrl").

-define(ADDRESS_ID, <<"address_id">>).

-define(MOD_CONFIG_CAT, <<(?KNM_CONFIG_CAT)/binary, ".telnyx2">>).

-define(IS_SANDBOX_PROVISIONING_TRUE
       ,kapps_config:get_is_true(?MOD_CONFIG_CAT, <<"sandbox_provisioning">>, 'false')
       ).

%% Telnyx validates the address for emergency use on creation unless told
%% otherwise; keep that on, an unvalidated address cannot carry 911.
-define(DEFAULT_COUNTRY_CODE
       ,kapps_config:get_ne_binary(?MOD_CONFIG_CAT, <<"default_country_code">>, <<"US">>)
       ).

%%------------------------------------------------------------------------------
%% @doc This function is called each time a number is saved, and will
%% provision e911 or remove the number depending on the state
%% @end
%%------------------------------------------------------------------------------
-spec save(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
save(PN) ->
    State = knm_phone_number:state(PN),
    save(PN, State).

-spec save(knm_phone_number:pn_record(), kz_term:ne_binary()) -> knm_phone_number:pn_record().
save(PN, ?NUMBER_STATE_RESERVED) ->
    maybe_update_e911(PN);
save(PN, ?NUMBER_STATE_IN_SERVICE) ->
    maybe_update_e911(PN);
save(PN, ?NUMBER_STATE_PORT_IN) ->
    maybe_update_e911(PN);
save(PN, _State) ->
    delete(PN).

%%------------------------------------------------------------------------------
%% @doc This function is called each time a number is deleted, and will
%% provision e911 or remove the number depending on the state
%% @end
%%------------------------------------------------------------------------------
-spec delete(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
delete(PN) ->
    case knm_phone_number:feature(PN, ?FEATURE_E911) of
        'undefined' -> PN;
        _Else ->
            lager:debug("removing e911 information"),
            {'ok', NewPN} = remove_number(PN),
            knm_providers:deactivate_feature(NewPN, ?FEATURE_E911)
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec maybe_update_e911(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
maybe_update_e911(PN) ->
    IsDryRun = knm_phone_number:dry_run(PN),
    maybe_update_e911(PN, (IsDryRun
                           orelse ?IS_SANDBOX_PROVISIONING_TRUE
                          )).

-spec maybe_update_e911(knm_phone_number:pn_record(), boolean()) -> knm_phone_number:pn_record().
maybe_update_e911(PN, 'true') ->
    CurrentE911 = knm_phone_number:feature(PN, ?FEATURE_E911),
    E911 = kz_json:get_ne_value(?FEATURE_E911, knm_phone_number:doc(PN)),
    NotChanged = kz_json:are_equal(CurrentE911, E911),
    case kz_term:is_empty(E911) of
        'true' ->
            lager:debug("dry run: information has been removed, updating upstream"),
            knm_providers:deactivate_feature(PN, ?FEATURE_E911);
        'false' when NotChanged ->
            PN;
        'false' ->
            lager:debug("dry run: information has been changed: ~s", [kz_json:encode(E911)]),
            knm_providers:activate_feature(PN, {?FEATURE_E911, E911})
    end;

maybe_update_e911(PN, 'false') ->
    CurrentE911 = knm_phone_number:feature(PN, ?FEATURE_E911),
    E911 = kz_json:get_ne_value(?FEATURE_E911, knm_phone_number:doc(PN)),
    NotChanged = kz_json:are_equal(CurrentE911, E911),
    case kz_term:is_empty(E911) of
        'true' ->
            lager:debug("information has been removed, updating upstream"),
            {'ok', NewPN} = remove_number(PN),
            knm_providers:deactivate_feature(NewPN, ?FEATURE_E911);
        'false' when NotChanged ->
            PN;
        'false' ->
            case update_e911(PN, E911) of
                {'ok', NewPN} ->
                    lager:debug("information has been changed: ~s", [kz_json:encode(E911)]),
                    knm_providers:activate_feature(NewPN, {?FEATURE_E911, E911});
                {'error', E} ->
                    lager:error("information update failed: ~p", [E]),
                    knm_errors:unspecified(E, PN)
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Point the number at a freshly created address, then release the one it
%% used to hold.
%% @end
%%------------------------------------------------------------------------------
-spec update_e911(knm_phone_number:pn_record(), kz_json:object()) ->
          {'ok', knm_phone_number:pn_record()} |
          {'error', kz_term:ne_binary()}.
update_e911(PN, AddressJObj) ->
    OldAddressId = address_id(PN),
    case create_address(PN, AddressJObj) of
        {'error', _}=E -> E;
        {'ok', AddressId} ->
            case assign_address(PN, AddressId) of
                {'error', _}=E -> E;
                {'ok', NewPN} ->
                    _ = delete_address(OldAddressId),
                    {'ok', NewPN}
            end
    end.

-spec create_address(knm_phone_number:pn_record(), kz_json:object()) ->
          {'ok', kz_term:ne_binary()} |
          {'error', kz_term:ne_binary() | any()}.
create_address(PN, AddressJObj) ->
    Body = e911_address(PN, AddressJObj),
    try knm_telnyx2_util:req('post', ["addresses"], Body) of
        Rep ->
            case kz_json:get_ne_binary_value([<<"data">>, <<"id">>], Rep) of
                'undefined' -> {'error', reason(Rep)};
                AddressId ->
                    lager:debug("created address ~s", [AddressId]),
                    {'ok', AddressId}
            end
    catch
        'throw':{'error', 'by_carrier', _, {_, Reason}} ->
            {'error', kz_term:to_binary(Reason)}
    end.

%%------------------------------------------------------------------------------
%% @doc Arm the number for emergency service against `AddressId'.
%% @end
%%------------------------------------------------------------------------------
-spec assign_address(knm_phone_number:pn_record(), kz_term:ne_binary()) ->
          {'ok', knm_phone_number:pn_record()} |
          {'error', kz_term:ne_binary()}.
assign_address(PN, AddressId) ->
    case emergency(PN, 'true', AddressId) of
        {'error', _}=E -> E;
        {'ok', _Rep} -> {'ok', set_address_id(PN, AddressId)}
    end.

%%------------------------------------------------------------------------------
%% @doc Disarm the number, then release the address it was pointing at.
%%
%% Order matters: Telnyx requires `emergency_address_id' on the disable call,
%% and refuses to delete an address that is still assigned.
%% @end
%%------------------------------------------------------------------------------
-spec remove_number(knm_phone_number:pn_record()) ->
          {'ok', knm_phone_number:pn_record()} |
          {'error', kz_term:ne_binary()}.
remove_number(PN) ->
    case address_id(PN) of
        'undefined' -> {'ok', PN};
        AddressId ->
            lager:debug("removing previously set address: ~s", [AddressId]),
            case emergency(PN, 'false', AddressId) of
                {'error', _}=E -> E;
                {'ok', _Rep} ->
                    _ = delete_address(AddressId),
                    {'ok', clear_address_id(PN)}
            end
    end.

-spec emergency(knm_phone_number:pn_record(), boolean(), kz_term:ne_binary()) ->
          {'ok', kz_json:object()} |
          {'error', kz_term:ne_binary()}.
emergency(PN, IsEnabling, AddressId) ->
    Body = kz_json:from_list([{<<"emergency_enabled">>, IsEnabling}
                             ,{<<"emergency_address_id">>, AddressId}
                             ]),
    try
        Id = knm_telnyx2_util:number_id(PN),
        Path = ["phone_numbers", kz_term:to_list(Id), "actions", "enable_emergency"],
        Rep = knm_telnyx2_util:req('post', Path, Body),
        case kz_json:get_ne_binary_value([<<"data">>, <<"emergency_status">>], Rep) of
            'undefined' ->
                lager:error("cannot ~s e911: ~s", [toggle(IsEnabling), kz_json:encode(Rep)]),
                {'error', reason(Rep)};
            Status ->
                lager:debug("~s e911 for ~s: ~s"
                           ,[toggle(IsEnabling), knm_phone_number:number(PN), Status]),
                {'ok', Rep}
        end
    catch
        'throw':{'error', 'by_carrier', _, {_, Reason}} ->
            {'error', kz_term:to_binary(Reason)};
        ?STACKTRACE(_T, E, ST)
        lager:error("~p ~p", [_T, E]),
        kz_log:log_stacktrace(ST),
        {'error', kz_term:to_binary(E)}
        end.

toggle('true') -> "enable";
toggle('false') -> "disable".

%%------------------------------------------------------------------------------
%% @doc Best-effort cleanup of an address that is no longer assigned.
%% @end
%%------------------------------------------------------------------------------
-spec delete_address(kz_term:api_ne_binary()) -> 'ok'.
delete_address('undefined') -> 'ok';
delete_address(AddressId) ->
    Path = ["addresses", kz_term:to_list(AddressId)],
    _ = kz_process:spawn(fun() -> catch knm_telnyx2_util:req('delete', Path) end),
    'ok'.

-spec address_id(knm_phone_number:pn_record()) -> kz_term:api_ne_binary().
address_id(PN) ->
    kz_json:get_ne_binary_value(?ADDRESS_ID, knm_phone_number:carrier_data(PN)).

%%------------------------------------------------------------------------------
%% @doc Write the address id straight into the carrier data.
%%
%% Not `knm_phone_number:update_carrier_data/2': that merges the existing data
%% over the new, so it can only add keys a number does not already carry. Both
%% things this module needs — pointing an already-provisioned number at a
%% replacement address, and dropping the id once the address is released —
%% would silently keep the stale id.
%% @end
%%------------------------------------------------------------------------------
-spec set_address_id(knm_phone_number:pn_record(), kz_term:ne_binary()) -> knm_phone_number:pn_record().
set_address_id(PN, AddressId) ->
    CarrierData = kz_json:set_value(?ADDRESS_ID, AddressId, knm_phone_number:carrier_data(PN)),
    knm_phone_number:set_carrier_data(PN, CarrierData).

-spec clear_address_id(knm_phone_number:pn_record()) -> knm_phone_number:pn_record().
clear_address_id(PN) ->
    CarrierData = kz_json:delete_key(?ADDRESS_ID, knm_phone_number:carrier_data(PN)),
    knm_phone_number:set_carrier_data(PN, CarrierData).

-spec reason(kz_json:object()) -> kz_term:ne_binary().
reason(RepJObj) ->
    %% v2 reports problems as a list of {code, title, detail} objects
    Reason = case kz_json:get_list_value(<<"errors">>, RepJObj) of
                 'undefined' -> kz_json:encode(RepJObj);
                 Errors -> kz_json:encode(kz_json:from_list([{<<"errors">>, Errors}]))
             end,
    lager:error("~s", [Reason]),
    Reason.

%%------------------------------------------------------------------------------
%% @doc Map Kazoo's e911 document onto Telnyx's v2 address fields.
%%
%% Kazoo already names most of these the way v2 does (`street_address',
%% `extended_address', `locality', `postal_code'); only `region' has to be
%% renamed to `administrative_area'.
%% @end
%%------------------------------------------------------------------------------
-spec e911_address(knm_phone_number:pn_record(), kz_json:object()) -> kz_json:object().
e911_address(PN, JObj) ->
    E911Name = kz_json:get_ne_binary_value(?E911_NAME, JObj),
    CallerName = knm_providers:e911_caller_name(PN, E911Name),
    kz_json:from_list(
      props:filter_empty(
        [{<<"business_name">>, CallerName}
        ,{<<"street_address">>, cleanse(kz_json:get_ne_binary_value(?E911_STREET1, JObj))}
        ,{<<"extended_address">>, cleanse(kz_json:get_ne_binary_value(?E911_STREET2, JObj))}
        ,{<<"locality">>, cleanse(kz_json:get_ne_binary_value(?E911_CITY, JObj))}
        ,{<<"administrative_area">>, cleanse(kz_json:get_ne_binary_value(?E911_STATE, JObj))}
        ,{<<"postal_code">>, kz_json:get_ne_binary_value(?E911_ZIP, JObj)}
        ,{<<"country_code">>, ?DEFAULT_COUNTRY_CODE}
        ])).

-spec cleanse(kz_term:api_ne_binary()) -> kz_term:api_binary().
cleanse('undefined') -> 'undefined';
cleanse(NEBin) ->
    Upper = kz_term:to_upper_binary(NEBin),
    << <<C>> || <<C>> <= Upper, is_ALnum_or_space(C)>>.

-spec is_ALnum_or_space(char()) -> boolean().
is_ALnum_or_space(C) when $0 =< C, C =< $9 -> 'true';
is_ALnum_or_space(C) when $A =< C, C =< $Z -> 'true';
is_ALnum_or_space(C) -> $\s =:= C.

%%% End of Module
