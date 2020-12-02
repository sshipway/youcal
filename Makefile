version=2.1
URL=https://youtrack.smxemail.com/
TOKEN=perm:xxxxxxxxxxxxxx
PORT=8080

# Use: "make container" to make the container; "make test" to test CGI script
# Testing requires URL and TOKEN above to be set correctly

container: .container
	@echo Done

complete:
	@touch Dockerfile
	@make container

.container: Dockerfile root
	docker build -t youcal:${version} -t youcal:latest .
	@touch .container

test: .container
	-docker stop youcal
	-docker rm youcal
	@echo Starting container
	docker run -d -e "YOUCAL_URL=${URL}" -e "YOUCAL_TOKEN=${TOKEN}" -p "${PORT}:80" --name youcal youcal:${version}
	@echo Testing youcal
	@echo "To access container use: docker exec -ti youcal sh"
	@echo Waiting for startup
	-sleep 5
	curl http://localhost:${PORT}/cgi-bin/youcal
	@echo Cleaning up after test
	docker stop youcal
	docker rm youcal
	@echo Tests all passed

