import fs from 'fs';
import path from 'path';

/**
 * Estado compartilhado do gerador de APK (/application/apk).
 * NAO e uma rota (sem `url`) — o handle-routes ignora este arquivo.
 *
 * Fluxo:
 *   POST /application/apk                -> cria um job, comeca a build em background
 *   GET  /application/apk/status/:id     -> { status, percent, stage, downloadUrl?, expiresInSec? }
 *   GET  /application/apk/download/:id   -> baixa o .apk (fica no disco ate expirar)
 *
 * O .apk gerado vive por DOWNLOAD_TTL_MS depois de pronto; um sweep periodico
 * apaga o arquivo e o registro.
 */

export const APP_BASE = path.resolve(process.cwd(), 'app_base');
export const DIST_DIR = path.join(APP_BASE, 'dist');
export const BUILDER = path.join(APP_BASE, 'apk-builder.sh');
export const BASE_APK = path.join(APP_BASE, 'base.apk');
export const KEYSTORE = path.join(APP_BASE, 'panel.jks');

export const DOWNLOAD_TTL_MS = 40 * 60 * 1000; // 40 min para baixar
const BUILD_TIMEOUT_MS = 15 * 60 * 1000; // job travado > 15 min -> descartado

export type JobStatus = 'building' | 'done' | 'error';

export interface Job {
  id: string;
  userId: string;
  status: JobStatus;
  percent: number;
  stage: string;
  file?: string;
  size?: number;
  sha256?: string;
  error?: string;
  createdAt: number;
  readyAt?: number;
  expiresAt?: number;
}

const jobs = new Map<string, Job>();

export function putJob(job: Job): void {
  jobs.set(job.id, job);
}

export function getJob(id: string): Job | undefined {
  return jobs.get(id);
}

export function dropJob(id: string): void {
  const job = jobs.get(id);
  if (job?.file) fs.unlink(job.file, () => undefined);
  jobs.delete(id);
}

let sweeping = false;
function sweep(): void {
  if (sweeping) return;
  sweeping = true;
  try {
    const now = Date.now();

    jobs.forEach((job, id) => {
      const stuck = job.status === 'building' && now - job.createdAt > BUILD_TIMEOUT_MS;
      const expired = job.expiresAt != null && now > job.expiresAt;
      if (stuck || expired) {
        if (job.file) fs.unlink(job.file, () => undefined);
        jobs.delete(id);
      }
    });

    // rede de seguranca: apaga .apk e .progress orfaos no dist/
    fs.readdir(DIST_DIR, (err, files) => {
      if (err) return;
      files.forEach((f) => {
        if (!/\.(apk)$/.test(f) && !f.startsWith('.progress-')) return;
        const p = path.join(DIST_DIR, f);
        fs.stat(p, (e, st) => {
          if (e) return;
          if (now - st.mtimeMs > DOWNLOAD_TTL_MS + 5 * 60 * 1000) fs.unlink(p, () => undefined);
        });
      });
    });
  } finally {
    sweeping = false;
  }
}

const timer = setInterval(sweep, 60 * 1000);
timer.unref();
