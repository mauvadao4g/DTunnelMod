import Authentication from '../../../middlewares/authentication';
import { FastifyReply, FastifyRequest, RouteOptions } from 'fastify';
import { getJob } from './_apk-jobs';

/**
 * GET /application/apk/status/:id
 * Progresso do job de geracao do APK.
 */

interface StatusReply {
  status: 'building' | 'done' | 'error';
  percent: number;
  stage: string;
  downloadUrl?: string;
  size?: number;
  sha256?: string;
  expiresInSec?: number;
  error?: string;
}

export default {
  url: '/application/apk/status/:id',
  method: 'GET',
  onRequest: [Authentication.user],
  handler: async (req: FastifyRequest, reply: FastifyReply) => {
    const { id } = req.params as { id: string };
    const job = getJob(id);

    if (!job || job.userId !== req.user.id) {
      reply.status(404);
      throw new Error('Geracao nao encontrada ou expirada.');
    }

    const body: StatusReply = {
      status: job.status,
      percent: job.percent,
      stage: job.stage,
    };

    if (job.status === 'done') {
      body.downloadUrl = `/application/apk/download/${job.id}`;
      body.size = job.size;
      body.sha256 = job.sha256;
      body.expiresInSec = Math.max(0, Math.round(((job.expiresAt || 0) - Date.now()) / 1000));
    }
    if (job.status === 'error') {
      body.error = job.error || 'Falha ao gerar o APK.';
    }

    reply.send(body);
  },
} as RouteOptions;
