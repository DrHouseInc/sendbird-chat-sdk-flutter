import 'package:json_annotation/json_annotation.dart';

import '../constant/enums.dart';
import '../models/user.dart';

part 'member.g.dart';

/// Represents a member of a channel.
@JsonSerializable()
class Member extends User {
  /// The state for invitation. The values of the property are `invited` and `joined`.
  /// The `invited` means that the user doesn't accept the invitation yet and the
  /// `joined` means that the user accepted the invitation manually or automatically
  MemberState state;

  /// True if current user has blocked this member, otherwise false
  bool isBlockedByMe = false;

  /// True if this member has blocked current user, otherwise false
  bool isBlockingMe = false;

  /// Muted state of this member in the channel
  bool isMuted;

  /// Role of this member in the channel
  @JsonKey(unknownEnumValue: Role.none)
  Role role;

  Member({
    this.state,
    this.isBlockedByMe,
    this.isBlockingMe,
    this.isMuted,
    this.role,
    String userId,
    String nickname,
    String profileUrl,
    bool isOnline,
    int lastSeenAt,
    List<String> preferredLanguages,
    String friendDiscoveryKey,
    String friendName,
    List<String> discoveryKeys,
    Map<String, String> metaData,
    bool requireAuth,
  }) : super(
          userId: userId,
          nickname: nickname,
          profileUrl: profileUrl,
          isOnline: isOnline,
          lastSeenAt: lastSeenAt,
          preferredLanguages: preferredLanguages,
          friendDiscoveryKey: friendDiscoveryKey,
          friendName: friendName,
          discoveryKeys: discoveryKeys,
          metaData: metaData,
          requireAuth: requireAuth,
        );

  // @override
  // bool operator ==(other) {
  //   if (identical(other, this)) return true;
  //   if (!(super == (other))) return false;

  //   return true;
  // }

  // @override
  // int get hashCode => super.hashCode;

  /// json serialization
  factory Member.fromJson(Map<String, dynamic> json) => _$MemberFromJson(json);
  Map<String, dynamic> toJson() => _$MemberToJson(this);
}