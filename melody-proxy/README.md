# Melody Proxy

YouTube akış URL'lerini po_token'suz çözmek istemez; 2025 sonrası tüm
genel akış yolları (InnerTube, Invidious, embed HTML) boş URL döndürür.
Bu proxy, yt-dlp'nin VISIONOS client'ı ile **gerçek** googlevideo ses
akışı URL'leri üretir. Melody akış/indirme isteklerini önce buraya sorar.

## Kurulum

```bash
cd melody-proxy
python3 -m venv venv
venv/bin/pip install -U yt-dlp
venv/bin/python server.py                # 0.0.0.0:8800
```

Yüksek verim için bir JS runtime önerilir (yt-dlp po_token üretimi için):

```bash
sudo apt install deno
```

## Endpoint'ler

| Endpoint | Açıklama |
|---|---|
| `GET /health` | Canlı mı, yt-dlp sürümü |
| `GET /api/v1/stream?video_id=ID` | Ses akış URL adayları (JSON) |
| `GET /api/v1/search?q=...&limit=12` | yt-dlp ytsearch şarkı listesi |

## Akış yanıtı örneği

```json
{
  "ok": true,
  "title": "...",
  "duration": 213,
  "thumbnail": "https://i.ytimg.com/vi/.../hqdefault.jpg",
  "channel": "...",
  "urls": [
    {
      "itag": "140",
      "ext": "m4a",
      "abr": 129,
      "quality": "medium",
      "url": "https://rr2...googlevideo.com/videoplayback?..."
    }
  ]
}
```

## Melody tarafında

Ayarlar → "Akış Sunucusu" alanına proxy URL'yi gir, örn.
`http://192.168.1.10:8800`. Melody akış/indirme/arama isteklerini
önce sunucuya sorar, ulaşamazsa Invidious'a düşer.

## Ağdan erişim

- Aynı LAN: `http://<makine-ip>:8800` (güvenlik duvarında 8800'ü aç)
- Uzaktan erişim: SSH tüneli (`ssh -L 8800:localhost:8800 makine`)
  veya kamuya açık bir deploy (Render/Railway). Token orada da olduğu gibi.