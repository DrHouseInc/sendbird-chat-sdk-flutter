import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../channel/base_channel.dart';
import '../channel/group_channel.dart';
import '../constant/contants.dart' as Constants;
import '../constant/enums.dart';
import '../event/event_manager.dart';
import '../models/command.dart';
import '../models/options.dart';
import '../models/responses.dart';
import '../models/state.dart';
import '../models/error.dart';
import '../models/user.dart';
import '../services/command/command_manager.dart';
import '../services/session/session_manager.dart';
import '../services/db/memory_cache_service.dart';
import '../services/network/api_client.dart';
import '../services/network/websocket_client.dart';
import '../utils/parsers.dart';

const sdk_version = '3.0.1';

/// Internal implementation for main class. Do not directly access this class.
class SendbirdSdkInternal with WidgetsBindingObserver {
  SendbirdState state = SendbirdState();

  SessionManager sessionManager = SessionManager();
  MemoryCacheStorage cache = MemoryCacheStorage();
  EventManager eventManager = EventManager();
  CommandManager cmdManager = CommandManager();

  Map<String, String> _extensions = {};

  ApiClient api = ApiClient();
  WebSocketClient webSocket;
  Completer<User> loginCompleter;

  StreamController<int> totalUnreadCountController;
  StreamController<ChannelMessageResponse> messageUpdateStreamController;
  StreamController<ChannelMessageResponse> messageReceiveStreamController;
  StreamController<BaseChannel> channelChangedStreamController;
  StreamController<GroupChannel> readStreamController;
  StreamController<GroupChannel> deliveryStreamController;
  StreamController<GroupChannel> usersTypingStreamController;
  StreamController<ConnectionEventType> connectionStreamController;

  Options options;

  Timer reconnectTimer;

  SendbirdSdkInternal({
    String appId,
    String apiToken,
    this.options,
  }) {
    api.initialize(appId: appId, token: apiToken);
    state.appId = appId;
    WidgetsBinding.instance?.addObserver(this);
  }

  void onWebSocketConnect() {
    state
      ..lastConnectedAt = DateTime.now().millisecondsSinceEpoch
      ..connected = true
      ..connecting = false;
  }

  //the socket has closed - return true to re-connect?
  void onWebSocketDisconnect() {
    state.connected = false;
    cmdManager.clearCompleters(error: WebSocketDisconnectError());
  }

  //Inbound Web Data
  void onWebSocketData(dynamic data) async {
    if (data == null) {
      return;
    }
    String stringCommand;

    if (data.runtimeType == String) {
      stringCommand = (data as String);
    } else {
      stringCommand =
          Utf8Decoder(allowMalformed: true).convert(data as List<int>);
    }

    if (stringCommand.isEmpty) {
      return;
    }

    //NOTE: using isolate somewhat buggy on debug mode
    //but it is required to process api first if corresponding event
    //comes in from socket
    Command cmd = await parseCommand(stringCommand);
    cmdManager.processCommand(cmd);
  }

  void onWebSocketError(Object error) {}

  Future<User> connect({
    String userId,
    String accessToken,
    String apiHost,
    String wsHost,
    bool reconnect = false,
  }) async {
    if (userId == null || userId.isEmpty) {
      throw InvalidParameterError();
    }

    userId = userId.trim();

    // already connected
    if (state.connected && state.userId == userId) {
      return state.currentUser;
    }

    // is already in progress to connect
    if (state.connecting && state.userId == userId && loginCompleter != null) {
      return loginCompleter.future;
    }

    state.userId = userId;
    state.connecting = true;

    _resetControllers();
    loginCompleter = Completer();

    webSocket?.close();
    webSocket = WebSocketClient(
      onWebSocketConnect,
      onWebSocketDisconnect,
      onWebSocketData,
      onWebSocketError,
    );

    String sessionKey;

    if (reconnect) {
      sessionKey = await sessionManager.getSessionKey();
      if (!state.reconnecting) eventManager.notifyReconnectionStarted();
    }

    apiHost = reconnect ? state.apiHost : apiHost ?? _getDefaultApiHost();
    wsHost = reconnect ? state.wsHost : wsHost ?? _getDefaultWsHost();

    state
      ..reconnecting = reconnect
      ..wsHost = wsHost
      ..apiHost = apiHost;

    api.initialize(baseUrl: apiHost, headers: {
      'SB-User-Agent': await this._sbUserAgent,
    });

    final ua = await this._sbUserAgent;
    var params = {
      'p': Platform.operatingSystem,
      'pv': Platform.operatingSystemVersion, //device_info
      'sv': sdk_version,
      'ai': state.appId,
      if (reconnect && sessionKey != null)
        'key': sessionKey
      else
        'user_id': userId,
      'SB-User-Agent': ua,
      'include_extra_data':
          'premium_feature_list,file_upload_size_limit,emoji_hash,application_attributes', //extra data
      'expiring_session': '0',
      if (accessToken != null) 'access_token': accessToken,
    };

    final fullWsHost = wsHost + '/?' + Uri(queryParameters: params).query;

    await webSocket.connect(fullWsHost);
    final user = await loginCompleter.future
        .timeout(Duration(seconds: options.connectionTimeout));

    loginCompleter = null;
    reconnectTimer = null;
    return user;
  }

  void _resetControllers() {
    totalUnreadCountController?.close();
    messageReceiveStreamController?.close();
    messageUpdateStreamController?.close();
    readStreamController?.close();
    deliveryStreamController?.close();
    channelChangedStreamController?.close();
    usersTypingStreamController?.close();
    connectionStreamController?.close();

    totalUnreadCountController = StreamController<int>.broadcast();
    messageUpdateStreamController =
        StreamController<ChannelMessageResponse>.broadcast();
    messageReceiveStreamController =
        StreamController<ChannelMessageResponse>.broadcast();
    channelChangedStreamController = StreamController<BaseChannel>.broadcast();
    readStreamController = StreamController<GroupChannel>.broadcast();
    deliveryStreamController = StreamController<GroupChannel>.broadcast();
    usersTypingStreamController = StreamController<GroupChannel>.broadcast();
    connectionStreamController =
        StreamController<ConnectionEventType>.broadcast();
  }

  void logout() {
    state = SendbirdState()..appId = state.appId;
    webSocket?.close();
    webSocket = null;
    sessionManager = SessionManager();
    cache = MemoryCacheStorage();
    eventManager = EventManager();
    cmdManager = CommandManager();
    api = ApiClient();
    api.initialize(appId: state.appId);
    loginCompleter = null;
    _resetControllers();
  }

  //reset reconnection logic
  void reconnect() {
    if (reconnectTimer != null) return;

    final task = state.reconnectTask;
    if (task.exceedRetryCount && task.hasRetriedLastChance) {
      task.increaseRetryCount();
      state.reconnecting = false;
      eventManager.notifyReconnectionFailed();
      return;
    }

    final backoffPeriod = task.backOffPeriod;
    task.increaseRetryCount();

    reconnectTimer = Timer(Duration(seconds: backoffPeriod), () {
      connect(reconnect: true, userId: state.userId);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _handleEnterBackground();
    if (state == AppLifecycleState.resumed) _handleEnterForeground();
  }

  _handleEnterBackground() {
    cache.markAsDirtyAll();
    //clear all timers
    state.connected = false;
    state.connecting = false;
    state.reconnecting = false;
    webSocket.close();
  }

  _handleEnterForeground() {
    //need to connect with existing session key
    //if previously connected
    //reconnecting
    if (state.currentUser != null)
      connect(userId: state.userId, reconnect: true);
  }

  String _getDefaultApiHost() {
    return 'api-' + state.appId + '.sendbird.com';
  }

  String _getDefaultWsHost() {
    return 'wss://ws-' + state.appId + '.sendbird.com';
  }

  Future<String> get _sbUserAgent async {
    final uikitVersion = _extensions[Constants.SbExtensionKeyUIKit];
    final core = '/c$sdk_version';
    final uikit = uikitVersion != null ? '/u$uikitVersion' : '';
    return 'flutter$core$uikit';
  }

  void addVersionExtension(String key, String version) {
    if (key != Constants.SbExtensionKeyUIKit ||
        key != Constants.SbExtensionKeySyncManager) {
      return;
    }
    _extensions[key] = version;
  }
}