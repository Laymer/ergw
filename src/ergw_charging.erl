%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_charging).

-export([validate_options/1, is_charging_event/3]).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

-define(DefaultChargingOpts, [{online, []}, {offline, []}]).
-define(DefaultOnlineChargingOpts, []).
-define(DefaultOfflineChargingOpts, [{triggers, []}]).
-define(DefaultOfflineChargingTriggers,
	[{'cgi-sai-change',		'container'},
	 {'ecgi-change',		'container'},
	 {'max-cond-change',		'cdr'},
	 {'ms-time-zone-change',	'cdr'},
	 {'qos-change',			'container'},
	 {'rai-change',			'container'},
	 {'rat-change',			'cdr'},
	 {'sgsn-sgw-change',		'cdr'},
	 {'sgsn-sgw-plmn-id-change',	'cdr'},
	 {'tai-change',			'container'},
	 {'tariff-switch-change',	'container'},
	 {'user-location-info-change',	'container'}]).

validate_options({Key, Opts})
  when is_atom(Key), ?is_opts(Opts) ->
    {Key, ergw_config:validate_options(fun validate_charging_options/2, Opts, ?DefaultChargingOpts, map)}.

validate_online_charging_options(Key, Opts) ->
    throw({error, {options, {{online, charging}, {Key, Opts}}}}).

validate_offline_charging_triggers(Key, Opt)
  when (Opt == 'cdr' orelse Opt == 'off') andalso
       (Key == 'max-cond-change' orelse
	Key == 'ms-time-zone-change' orelse
	Key == 'rat-change' orelse
	Key == 'sgsn-sgw-change' orelse
	Key == 'sgsn-sgw-plmn-id-change') ->
    Opt;
validate_offline_charging_triggers(Key, Opt)
  when (Opt == 'container' orelse Opt == 'off') andalso
       (Key == 'cgi-sai-change' orelse
	Key == 'ecgi-change' orelse
	Key == 'qos-change' orelse
	Key == 'rai-change' orelse
	Key == 'rat-change' orelse
	Key == 'sgsn-sgw-change' orelse
	Key == 'sgsn-sgw-plmn-id-change' orelse
	Key == 'tai-change' orelse
	Key == 'tariff-switch-change' orelse
	Key == 'user-location-info-change') ->
    Opt;
validate_offline_charging_triggers(Key, Opts) ->
    throw({error, {options, {{offline, charging, triggers}, {Key, Opts}}}}).

validate_offline_charging_options(triggers, Opts) ->
    ergw_config:validate_options(fun validate_offline_charging_triggers/2,
				 Opts, ?DefaultOfflineChargingTriggers, map);
validate_offline_charging_options(Key, Opts) ->
    throw({error, {options, {{offline, charging}, {Key, Opts}}}}).

validate_charging_options(online, Opts) ->
    ergw_config:validate_options(fun validate_online_charging_options/2,
				 Opts, ?DefaultOnlineChargingOpts, map);
validate_charging_options(offline, Opts) ->
    ergw_config:validate_options(fun validate_offline_charging_options/2,
				 Opts, ?DefaultOfflineChargingOpts, map);
validate_charging_options(Key, Opts) ->
    throw({error, {options, {charging, {Key, Opts}}}}).

%%%===================================================================
%%% API
%%%===================================================================

is_charging_event(offline, Evs, Config)
  when is_map(Config) ->
    Filter =
	maps:get(triggers,
		 maps:get(offline, Config, #{}), #{}),
    is_offline_charging_event(Evs, Filter);
is_charging_event(online, _, _Config) ->
    true;
is_charging_event(_, _, _Config) ->
    [].

%%%===================================================================
%%% Helper functions
%%%===================================================================

is_offline_charging_event(Evs, Filter)
  when is_map(Filter) ->
    Es = ordsets:from_list([maps:get(Ev, Filter, off) || Ev <- Evs]),
    ordsets:del_element(off, Es).
