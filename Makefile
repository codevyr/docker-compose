CONTEXT ?= default

build: 
	docker compose build

load-codevyr: build
	docker save codevyr:prod | gzip | ssh codevyr 'gunzip | docker load'

load-askld: build
	docker save askld:latest | gzip | ssh codevyr 'gunzip | docker load'

load: load-codevyr load-askld

load-index:
	chmod -R go+w ../index/
	rsync -avz ../index codevyr:~/

deploy:
	docker --context $(CONTEXT) compose up -d

reload:
	docker --context $(CONTEXT) compose restart
