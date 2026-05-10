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

deploy-local:
	docker compose -f compose.yaml -f compose.local.yaml up -d

deploy-dev:
	docker compose -f compose.yaml -f compose.dev.yaml up -d

deploy-remote:
	docker --context codevyr compose -f compose.yaml up -d

reload-local:
	docker compose -f compose.yaml -f compose.local.yaml restart

reload-dev:
	docker compose -f compose.yaml -f compose.dev.yaml restart

reload-remote:
	docker --context codevyr compose -f compose.yaml restart


.PHONY: deploy reload
deploy: deploy-remote
reload: reload-remote
