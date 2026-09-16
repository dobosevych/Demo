# Shared install layer.
FROM node:22-alpine AS base

WORKDIR /srv

COPY package.json ./
RUN npm install

COPY . .

# Static bundle for the CloudFront deployment. `make frontend-build` targets this
# stage and copies /srv/dist out. VITE_API_URL is baked in here, at build time;
# an empty value produces a site that renders but cannot reach an API.
FROM base AS build

ARG VITE_API_URL=""
ENV VITE_API_URL=${VITE_API_URL}

RUN npm run build

# Default stage, so `docker compose build` still gets the dev server.
FROM base AS dev

EXPOSE 5173

CMD ["npm", "run", "dev"]
