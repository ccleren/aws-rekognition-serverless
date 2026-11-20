# jsPDF (autoalojado)

Única dependencia de terceros del frontend. Se sirve desde el propio CloudFront (sin CDN) para cumplir la CSP `script-src 'self'`, y se carga bajo demanda solo al exportar el informe.

| Campo | Valor |
|---|---|
| Paquete | [`jspdf`](https://www.npmjs.com/package/jspdf) **4.2.1** |
| Fichero | `dist/jspdf.umd.min.js`, sin modificar |
| Integridad del paquete npm | `sha512-YyAXyvnmjTbR4bHQRLzex3CuINCDlQnBqoSYyjJwTP2x9jDLuKDzy7aKUl0hgx3uhcl7xzg32agn5vlie6HIlQ==` |
| SHA-256 de `jspdf.umd.min.js` | `e6551fcdc32f09d6853b2c5126d18d01d9447e0da618a41a11ebeee0f6c20d54` |
| Licencia | MIT ([LICENSE](LICENSE)). El build UMD incluye `fflate` y `fast-png`, ambos MIT |

El build contiene referencias a `html2canvas`, `dompurify` y `canvg`, que solo se cargan si se usa `doc.html()` o SVG; aquí no se usan. No contiene `eval` ni `new Function`.

## Actualizar

```bash
npm pack jspdf@<versión>              # descarga el .tgz y muestra su integridad
tar xzf jspdf-<versión>.tgz
cp package/dist/jspdf.umd.min.js package/LICENSE frontend/vendor/jspdf/
sha256sum frontend/vendor/jspdf/jspdf.umd.min.js
```

Actualiza la versión y los hashes de esta tabla.
