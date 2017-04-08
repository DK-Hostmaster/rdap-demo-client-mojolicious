FROM debian:jessie-slim
MAINTAINER jonasbn

RUN apt-get update -y
RUN apt-get install -y curl build-essential carton libssl-dev 

COPY . /usr/src/app
WORKDIR /usr/src/app
RUN carton install --deployment

EXPOSE 3000

CMD carton exec -- morbo --listen https://*:3000 client.pl
