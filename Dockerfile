FROM debian:jessie-slim
MAINTAINER jonasbn

RUN apt-get update -y
RUN apt-get install -y curl build-essential carton libssl-dev 

WORKDIR /usr/src/app
COPY cpanfile.snapshot /usr/src/app
COPY cpanfile /usr/src/app
RUN carton install --deployment

COPY . /usr/src/app
EXPOSE 5000

CMD carton exec -- morbo --listen https://*:5000 client.pl
