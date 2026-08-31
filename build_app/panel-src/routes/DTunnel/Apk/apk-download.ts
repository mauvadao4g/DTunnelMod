import fs from 'fs';
import Authentication from '../../../middlewares/authentication';
import { FastifyReply, FastifyRequest, RouteOptions } from 'fastify';
import { getJob } from './_apk-jobs';

/**
 * GET /application/apk/download/:id
 * Entrega o .apk gerado. O arquivo permanece no disco ate expirar (40 min),
 * entao o mesmo link pode ser usado varias vezes nesse periodo.
 */

export default {
  url: '/application/apk/download/:id',
  method: 'GET',
  onRequest: [Authentication.user],
  handler: async (req: FastifyRequest, reply: FastifyReply) => {
    const { id } = req.params as { id: string };
    const job = getJob(id);

    if (!job || job.userId !== req.user.id) {
      reply.status(404);
      throw new Error('APK nao encontrado.');
    }
    if (job.status !== 'done' || !job.file) {
      reply.status(409);
      throw new Error('O APK ainda esta sendo gerado.');
    }
    if ((job.expiresAt && Date.now() > job.expiresAt) || !fs.existsSync(job.file)) {
      reply.status(410);
      throw new Error('O link expirou. Gere o APK novamente.');
    }

    const filename = `DTunnelMod-${req.user.username}.apk`;
    const size = job.size || fs.statSync(job.file).size;

    reply
      .header('Content-Type', 'application/vnd.android.package-archive')
      .header('Content-Disposition', `attachment; filename="${filename}"`)
      .header('Content-Length', String(size))
      .header('X-Apk-Sha256', job.sha256 || '');

    return reply.send(fs.createReadStream(job.file));
  },
} as RouteOptions;
