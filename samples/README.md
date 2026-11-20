# Archivos de prueba

Imágenes y vídeos para probar la aplicación. Este repositorio es público, así que **solo se incluyen archivos propios o con licencia CC0 / dominio público**, y cada uno se anota en la tabla con su origen y licencia.

> No subas a la aplicación (ni añadas aquí) imágenes con **personas identificables, matrículas, documentos u otros datos personales**.

## Inventario

| Archivo | Tipo | Tamaño | Origen | Licencia | Para probar |
|---|---|---|---|---|---|
| *(vacío por ahora)* | | | | | |

Cuando añadas un archivo, rellena una fila. Ejemplo:

| `street.jpg` | JPEG | 1,2 MiB | Foto propia | CC0 1.0 | Imagen con varias instancias (cajas) |

## Fuentes recomendadas

- **Fotos y vídeos propios**, publicados aquí como CC0.
- **Wikimedia Commons**, filtrando por *CC0* o *Public domain* (comprueba la licencia en la página de cada archivo).
- Evita bancos con licencia propia (Unsplash, Pexels, Pixabay): permiten usar las imágenes, pero no son CC0 y su redistribución en un repositorio tiene matices.

## Casos que conviene cubrir

| Caso | Resultado esperado |
|---|---|
| JPEG o PNG normal (< 4 MiB) | Etiquetas y cajas en pocos segundos |
| JPEG con extensión `.png` | Se acepta: el tipo se detecta por la firma del archivo, no por la extensión |
| MP4 H.264 corto (< 4 MiB) | Etiquetas agregadas con su primera aparición, tras decenas de segundos o minutos |
| MP4 HEVC/H.265 | `FAILED` con `unsupported_video_codec` |
| Archivo de texto renombrado a `.jpg` | 400 `unsupported_type` |
| Archivo > 4 MiB | Rechazado en el cliente; si se fuerza, 400 `file_too_large` |

## Preparar un vídeo compatible

Rekognition Video solo admite **H.264** en MP4/MOV. Con `ffmpeg` se puede convertir y recortar para quedar por debajo de 4 MiB:

```bash
ffmpeg -i entrada.mov -t 15 -vf "scale=-2:480" -c:v libx264 -preset slow -crf 28 \
       -pix_fmt yuv420p -an -movflags +faststart salida.mp4
```

- `-t 15`: 15 segundos como máximo · `scale=-2:480`: 480 px de alto · `-an`: sin audio (no se analiza).
- Si sigue superando 4 MiB, sube `-crf` (p. ej. 32) o reduce la duración.
- Comprueba el códec con `ffprobe -v error -select_streams v:0 -show_entries stream=codec_name salida.mp4` (debe decir `h264`).
