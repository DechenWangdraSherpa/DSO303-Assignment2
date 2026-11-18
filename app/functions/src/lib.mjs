// Shared helpers for every Lambda in the platform.
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { SQSClient } from '@aws-sdk/client-sqs';
import { S3Client } from '@aws-sdk/client-s3';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import pg from 'pg';
import crypto from 'node:crypto';

const region = process.env.AWS_REGION || 'us-east-1';

export const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }), {
  marshallOptions: { removeUndefinedValues: true },
});
export const sqs = new SQSClient({ region });
export const s3 = new S3Client({ region, forcePathStyle: process.env.S3_PATH_STYLE === 'true' });

// Client used only to SIGN upload URLs handed to the browser. On real AWS this is the
// normal regional endpoint; on the emulator the browser must reach localhost, not the
// Docker-internal hostname the Lambda itself uses.
export const s3Presign = new S3Client({
  region,
  forcePathStyle: process.env.S3_PATH_STYLE === 'true',
  ...(process.env.PUBLIC_S3_ENDPOINT ? { endpoint: process.env.PUBLIC_S3_ENDPOINT } : {}),
});

// ---- Aurora PostgreSQL (credentials come from Secrets Manager, never env vars) ----
let pool;
export async function db() {
  if (pool) return pool;
  const sm = new SecretsManagerClient({ region });
  const sec = await sm.send(new GetSecretValueCommand({ SecretId: process.env.DB_SECRET_ARN }));
  const c = JSON.parse(sec.SecretString);
  pool = new pg.Pool({
    host: process.env.DB_HOST || c.host,
    port: Number(process.env.DB_PORT || c.port || 5432),
    user: c.username,
    password: c.password,
    database: process.env.DB_NAME || 'exams',
    max: 2,                      // small per-container pool; RDS Proxy multiplexes on AWS
    idleTimeoutMillis: 10_000,
    connectionTimeoutMillis: 15_000, // a cold connection can be slow on a busy machine
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : undefined,
  });
  return pool;
}

// ---- HTTP helpers for API Gateway HTTP API (payload v2) ----
export const json = (statusCode, body) => ({
  statusCode,
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(body),
});

// Identity of the caller. On AWS, API Gateway's Cognito JWT authorizer has already verified
// the token and passes the claims. Floci's JWT authorizer rejects every token, so with
// AUTH_MODE=emulator the route has no gateway authorizer and we do the same checks here:
// RS256 signature against the user pool's JWKS, issuer, expiry and app client.
let jwks;
async function verifyCognitoJwt(token) {
  const [h, p, s] = token.split('.');
  if (!s) return null;
  const header = JSON.parse(Buffer.from(h, 'base64url'));
  const claims = JSON.parse(Buffer.from(p, 'base64url'));
  const pool = process.env.COGNITO_POOL_ID;
  if (header.alg !== 'RS256' || !String(claims.iss).endsWith(`/${pool}`)) return null;
  if (!claims.exp || claims.exp * 1000 < Date.now()) return null;
  if ((claims.aud || claims.client_id) !== process.env.COGNITO_CLIENT_ID) return null;
  if (!jwks) jwks = (await (await fetch(`${process.env.COGNITO_ISSUER}/.well-known/jwks.json`)).json()).keys;
  const jwk = jwks.find((k) => k.kid === header.kid) || jwks[0];
  const ok = crypto.verify('RSA-SHA256', Buffer.from(`${h}.${p}`), crypto.createPublicKey({ key: jwk, format: 'jwk' }), Buffer.from(s, 'base64url'));
  return ok ? claims : null;
}

export async function caller(event) {
  let claims = event?.requestContext?.authorizer?.jwt?.claims;
  if (!claims && process.env.AUTH_MODE === 'emulator') {
    const h = event.headers?.authorization || event.headers?.Authorization || '';
    try { claims = await verifyCognitoJwt(h.replace(/^Bearer\s+/i, '')); } catch { claims = null; }
  }
  if (!claims) return null;
  let groups = claims['cognito:groups'] || [];
  if (typeof groups === 'string') groups = groups.replace(/[\[\]]/g, '').split(/[ ,]+/).filter(Boolean);
  return {
    sub: claims.sub,
    username: claims.username || claims['cognito:username'] || claims.sub,
    email: claims.email,
    groups,
    is: (g) => groups.includes(g),
  };
}

export const log = (msg, extra = {}) => console.log(JSON.stringify({ level: 'info', msg, ...extra }));
