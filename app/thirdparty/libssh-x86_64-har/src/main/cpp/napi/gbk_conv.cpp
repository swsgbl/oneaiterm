/*
 * Copyright (C) 2025 upstream
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* GBK<->UTF-8 conversion built on the generated static table. ASCII (0x00-0x7F)
 * passes through identically, matching real GBK semantics. */

#include "napi/gbk_table.h"

#include <algorithm>
#include <cstring>

namespace upstream {

static const char kReplacementUtf8[] = "\xEF\xBF\xBD"; // U+FFFD

static const GbkEntry *GbkFind(const GbkEntry *tab, size_t n, uint16_t gbk) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (tab[mid].gbk < gbk) {
            lo = mid + 1;
        } else if (tab[mid].gbk > gbk) {
            hi = mid;
        } else {
            return &tab[mid];
        }
    }
    return nullptr;
}

uint16_t GbkToUni(uint16_t gbk) {
    const GbkEntry *e = GbkFind(kGbkToUni, kGbkToUniCount, gbk);
    return e != nullptr ? e->uni : 0;
}

static const UniEntry *UniFind(uint16_t uni) {
    size_t lo = 0, hi = kUniToGbkCount;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (kUniToGbk[mid].uni < uni) {
            lo = mid + 1;
        } else if (kUniToGbk[mid].uni > uni) {
            hi = mid;
        } else {
            return &kUniToGbk[mid];
        }
    }
    return nullptr;
}

uint16_t UniToGbk(uint16_t uni) {
    const UniEntry *e = UniFind(uni);
    return e != nullptr ? e->gbk : 0;
}

static void AppendUtf8(std::string &out, uint32_t cp) {
    if (cp < 0x80) {
        out.push_back((char)cp);
    } else if (cp < 0x800) {
        out.push_back((char)(0xC0 | (cp >> 6)));
        out.push_back((char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back((char)(0xE0 | (cp >> 12)));
        out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back((char)(0x80 | (cp & 0x3F)));
    } else {
        out.push_back((char)(0xF0 | (cp >> 18)));
        out.push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back((char)(0x80 | (cp & 0x3F)));
    }
}

size_t GbkDecode(const char *in, size_t len, std::string &out) {
    size_t i = 0;
    while (i < len) {
        unsigned char c = (unsigned char)in[i];
        if (c < 0x80) {
            out.push_back((char)c);
            i += 1;
            continue;
        }
        if (i + 1 >= len) {
            break; // trailing lead byte: hold back for next chunk
        }
        unsigned char c2 = (unsigned char)in[i + 1];
        uint16_t code = (uint16_t)((c << 8) | c2);
        uint16_t uni = GbkToUni(code);
        if (uni != 0) {
            AppendUtf8(out, uni);
            i += 2;
        } else {
            out.append(kReplacementUtf8, 3);
            i += 1; // resync one byte
        }
    }
    return i;
}

bool Utf8ToGbk(const std::string &in, std::string &out) {
    bool ok = true;
    size_t i = 0;
    while (i < in.size()) {
        unsigned char c = (unsigned char)in[i];
        if (c < 0x80) {
            out.push_back((char)c);
            i += 1;
            continue;
        }
        // decode one UTF-8 scalar
        size_t seqLen = 0;
        uint32_t cp = 0;
        if ((c & 0xE0) == 0xC0) {
            seqLen = 2;
            cp = c & 0x1F;
        } else if ((c & 0xF0) == 0xE0) {
            seqLen = 3;
            cp = c & 0x0F;
        } else if ((c & 0xF8) == 0xF0) {
            seqLen = 4;
            cp = c & 0x07;
        } else {
            out.push_back('?');
            ok = false;
            i += 1;
            continue;
        }
        if (i + seqLen > in.size()) {
            break; // truncated tail: drop silently (caller re-sends whole line)
        }
        bool cont = true;
        for (size_t k = 1; k < seqLen; k++) {
            unsigned char cc = (unsigned char)in[i + k];
            if ((cc & 0xC0) != 0x80) {
                cont = false;
                break;
            }
            cp = (cp << 6) | (cc & 0x3F);
        }
        if (!cont) {
            out.push_back('?');
            ok = false;
            i += 1;
            continue;
        }
        if (cp > 0xFFFF) {
            out.push_back('?'); // non-BMP never exists in GBK
            i += seqLen;
            continue;
        }
        uint16_t gbk = UniToGbk((uint16_t)cp);
        if (gbk == 0) {
            out.push_back('?');
        } else {
            out.push_back((char)(gbk >> 8));
            out.push_back((char)(gbk & 0xFF));
        }
        i += seqLen;
    }
    return ok;
}

} // namespace upstream
