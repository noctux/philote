FROM perl:5.20

RUN apt-get -y update 
RUN apt-get -y upgrade
RUN cpanm Data::Compare

COPY src/ /app/src
COPY Makefile /app
RUN mkdir /app/library
WORKDIR /app

CMD [ "make" ]
