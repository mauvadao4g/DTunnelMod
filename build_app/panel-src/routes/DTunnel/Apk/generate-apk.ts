import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import { execFile } from 'child_process';
import Authentication from '../../../middlewares/authentication';
import { FastifyReply, FastifyRequest, RouteOptions } from 'fastify';
import { BASE_APK, BUILDER, DIST_DIR, DOWNLOAD_TTL_MS, KEYSTORE, Job, putJob } from './_apk-jobs';

/**
 * POST /application/apk
 * Dispara a geracao do APK do usuario logado em background e devolve { id }.
 * O front acompanha em GET /application/apk/status/:id.
 */

interface BuildJson {
  apk: string;
  sha256: string;
  size: number;
}

function startBuild(job: Job, userId: string, url: string): void {
  const progressFile = path.join(DIST_DIR, `.progress-${job.id}`);
  const outFile = path.join(DIST_DIR, `DTMod-${job.id}.apk`);

  const args = [
    BUILDER,
    '--user-id', userId,
    '--url', url,
    '--base', BASE_APK,
    '--keystore', KEYSTORE,
    '--storepass', process.env.APK_KEYSTORE_PASS || 'dtunnelmod',
    '--out', outFile,
    '--progress-file', progressFile,
    '--print-json',
  ];

  const poll = setInterval(() => {
    fs.readFile(progressFile, 'utf8', (err, data) => {
      if (err || job.status !== 'building') return;
      const last = data.trim().split('\n').pop() || '';
      const sep = last.indexOf('|');
      if (sep < 0) return;
      const pct = parseInt(last.slice(0, sep), 10);
      if (!Number.isNaN(pct)) job.percent = Math.min(99, Math.max(job.percent, pct));
      job.stage = last.slice(sep + 1) || job.stage;
    });
  }, 1000);
  poll.unref();

  execFile('bash', args, { timeout: 6 * 60 * 1000, maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
    clearInterval(poll);
    fs.unlink(progressFile, () => undefined);

    if (err) {
      job.status = 'error';
      job.error = 'Nao foi possivel gerar o APK. Tente novamente em instantes.';
      // eslint-disable-next-line no-console
      console.error('[apk] build falhou:', stderr || err.message);
      fs.unlink(outFile, () => undefined);
      return;
    }

    try {
      const line = stdout.trim().split('\n').pop() || '';
      const res = JSON.parse(line) as BuildJson;
      job.status = 'done';
      job.percent = 100;
      job.stage = 'concluido';
      job.file = res.apk;
      job.size = res.size;
      job.sha256 = res.sha256;
      job.readyAt = Date.now();
      job.expiresAt = job.readyAt + DOWNLOAD_TTL_MS;
    } catch {
      job.status = 'error';
      job.error = 'Resposta invalida do gerador de APK.';
    }
  });
}

export default {
  url: '/application/apk',
  method: 'POST',
  onRequest: [Authentication.user],
  handler: async (req: FastifyRequest, reply: FastifyReply) => {
    const publicUrl = process.env.PUBLIC_URL;
    if (!publicUrl) {
      reply.status(500);
      throw new Error('PUBLIC_URL nao definido no .env do painel.');
    }
    if (!fs.existsSync(BUILDER) || !fs.existsSync(BASE_APK)) {
      reply.status(503);
      throw new Error('O gerador de APK nao esta instalado neste painel.');
    }

    fs.mkdirSync(DIST_DIR, { recursive: true });

    const id = crypto.randomBytes(9).toString('hex');
    const job: Job = {
      id,
      userId: req.user.id,
      status: 'building',
      percent: 3,
      stage: 'iniciando',
      createdAt: Date.now(),
    };
    putJob(job);
    startBuild(job, req.user.id, publicUrl);

    reply.status(202).send({ id, statusUrl: `/application/apk/status/${id}` });
  },
} as RouteOptions;
