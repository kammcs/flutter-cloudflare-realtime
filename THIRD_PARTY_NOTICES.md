# Third-party notices

## partytracks

Parts of this package are ported from [partytracks](https://github.com/cloudflare/partykit/tree/main/packages/partytracks) (version 0.0.56, `cloudflare/partykit` commit `f0a2e97`):

| This package | partytracks source |
|---|---|
| `lib/src/session/op_queue.dart` (`OpQueue`, `BatchDispatcher`) | `src/client/Peer.utils.ts` (`FIFOScheduler`, `BulkRequestDispatcher`) |
| `lib/src/session/sfu_session.dart`, `track_publication.dart` (session setup, push/pull/update/close flows, transceiver lookup, the wait for sent media, ICE-disconnect timeout) | `src/client/PartyTracks.ts` |
| `lib/src/session/track_name.dart` (UUID track names) | `src/client/PartyTracks.ts` (`crypto.randomUUID()`) |

```
ISC License

Copyright 2024 Sunil Pai <spai@cloudflare.com>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```
