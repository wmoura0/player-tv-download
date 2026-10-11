/// Modelo representando uma conta autenticada via API Xtream Codes.
class XtreamAccount {
  final String serverUrl;
  final String username;
  final bool isAuthorized;
  final String status;
  final DateTime? expirationDate;
  final int? maxConnections;
  final int? activeConnections;
  final Map<String, dynamic>? rawUserInfo;
  final Map<String, dynamic>? rawServerInfo;

  const XtreamAccount({
    required this.serverUrl,
    required this.username,
    required this.isAuthorized,
    required this.status,
    this.expirationDate,
    this.maxConnections,
    this.activeConnections,
    this.rawUserInfo,
    this.rawServerInfo,
  });

  factory XtreamAccount.fromApiResponse({
    required String serverUrl,
    required String username,
    required Map<String, dynamic> json,
  }) {
    final userInfo = json['user_info'] as Map<String, dynamic>? ?? {};
    final serverInfo = json['server_info'] as Map<String, dynamic>? ?? {};

    final authValue = userInfo['auth'];
    final isAuth = authValue == 1 || authValue == '1';
    final statusStr = userInfo['status']?.toString() ?? (isAuth ? 'Ativo' : 'Inativo');

    DateTime? expDate;
    final expRaw = userInfo['exp_date'];
    if (expRaw != null) {
      if (expRaw is int) {
        expDate = DateTime.fromMillisecondsSinceEpoch(expRaw * 1000);
      } else if (expRaw is String) {
        final timestamp = int.tryParse(expRaw);
        if (timestamp != null) {
          expDate = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
        } else {
          expDate = DateTime.tryParse(expRaw);
        }
      }
    }

    final maxConn = int.tryParse(userInfo['max_connections']?.toString() ?? '');
    final activeConn = int.tryParse(userInfo['active_cons']?.toString() ?? '');

    return XtreamAccount(
      serverUrl: serverUrl,
      username: username,
      isAuthorized: isAuth,
      status: statusStr,
      expirationDate: expDate,
      maxConnections: maxConn,
      activeConnections: activeConn,
      rawUserInfo: userInfo,
      rawServerInfo: serverInfo,
    );
  }
}
