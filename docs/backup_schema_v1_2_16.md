# JessFlix Fire TV — Backup Lógico de Schemas (Base `v1.2.16+19`, commit `a152169`)

**Data do Backup:** 2026-11-25  
**Branch Base:** `main` (`a152169`)  
**Branch de Trabalho:** `fix/firetv-general-audit-stability`

---

## 1. Escopo de Conta e Perfil
- `UserProfileService.getScopedKey(baseKey)`:
  - Perfil padrão (`default_profile`): retorna `baseKey` sem sufixo (retrocompatibilidade).
  - Demais perfis: retorna `${baseKey}_p_${_currentProfileId}`.
- `PlaybackProgressService.buildAccountKey(serverUrl, username)`:
  - Formato: `${cleanServer}_$cleanUser` (letras/dígitos preservados, demais caracteres convertidos em `_`).
  - Melhoria planejada: normalizar `serverUrl` via `XtreamAuthService.normalizeServerUrl` antes de higienizar quando parecer URL real, mantendo idênticas chaves antigas já normalizadas (`http://host` -> `http___host`).

---

## 2. Formato de Favoritos (`SharedPreferences`)
- **Chave:** `player_fav_${cleanScope}_v1` (via `FavoritesService.buildStorageKey(scopeKey)`)
- **Valor:** `List<String>` onde cada item é JSON de `FavoriteItem`:
  ```json
  {
    "id": "136850",
    "scopeKey": "http___servidor_user",
    "type": "series",
    "name": "Diários de um Vampiro",
    "iconUrl": "https://...",
    "rating": "8.5",
    "categoryId": "95",
    "containerExtension": null,
    "streamUrl": null,
    "directSource": null,
    "addedAt": "2026-11-25T10:00:00.000"
  }
  ```

---

## 3. Formato de Progresso de Filmes, Séries e Continuar Assistindo (`SharedPreferences`)
- **Progresso de Filme (VOD):** `vod_prog_${effective}_$streamId`
  - JSON: `{"pos": <int_ms>, "dur": <int_ms>, "time": <int_epoch_ms>}`
- **Progresso de Episódio:** `series_prog_${effective}_${seriesId}_$episodeId`
  - JSON: `{"pos": <int_ms>, "dur": <int_ms>, "time": <int_epoch_ms>}`
- **Último Episódio da Série:** `series_last_${effective}_$seriesId`
  - JSON: `{"episodeId": <int>, "seasonNumber": <int>, "episodeNum": <int>, "isPromotedNext": <bool>, "time": <int_epoch_ms>}`
- **Lista Continuar Assistindo (Home):** `continue_watching_$effective`
  - `List<String>` de JSONs de `ContinueWatchingItem`:
    - `streamId` (`int`), `seriesId` (`int?`), `type` (`'movie'|'series'`), `title` (`String`), `subtitle` (`String?`), `coverUrl` (`String?`), `pos` (`int ms`), `dur` (`int ms`), `time` (`int epoch ms`), `containerExtension` (`String?`), `categoryId` (`String?`), `seasonNumber` (`int?`), `episodeNum` (`int?`), `manualResetAt` (`int? epoch ms`).
- **Novos campos aditivos retrocompatíveis em `ContinueWatchingItem`:**
  - `hiddenFromHomeAt` (`int? epoch ms`) — ocultar da Home preservando progresso;
  - `completedAt` (`int? epoch ms`) — conclusão explícita;
  - `historyClearedAt` (`int? epoch ms`) — limpeza explícita de histórico.

---

## 4. Ledger Local e Firestore (`firestore.rules`)
- **Ledger Local (`SharedPreferences`):** `cloud_sync_ledger_$effective` (JSON object `{ "movie_<id>" | "series_<seriesId>": ContinueWatchingItem }`, máximo 30 itens / 60.000 bytes).
- **Coleção Firestore:** `/sync_profiles/{syncId}` onde `syncId` = SHA-256 hex (64 chars) de `jessflix_sync_v1:${effectiveAccountKey.trim().toLowerCase()}`.
- **Campos top-level permitidos por `firestore.rules` (imutáveis sem deploy de regras):**
  - `syncId` (64-char hex string)
  - `updatedAtMs` (int > 0)
  - `lastUid` (string 1..128 == `request.auth.uid`)
  - `itemsJson` (string 2..65536 bytes — schema interno livre no JSON).

---

## 5. Instruções de Rollback
Caso seja necessário reverter as alterações desta auditoria:
```powershell
git checkout main
```
Como nenhuma chave existente foi renomeada ou removida e os campos adicionados em `ContinueWatchingItem` são opcionais/aditivos dentro de `itemsJson`, todos os dados existentes dos usuários permanecem 100% compatíveis.
