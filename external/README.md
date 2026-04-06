<img src="./docs/SeverenceSMW.png"/>

# Severance: Secure SPARQL Service

# Installing the External Component

## Prerequisites

1. docker compose
2. A mechanism for generating an Auth token (or a pre-defined auth token)

## Configuration

1. Make a copy of the env_template file and edit it 
2. save it as .env in the same folder as the docker-compose file

### env_template

    ENCRYPTION_KEY_HEX=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    RESULT_FORMAT=csv                  # or "json"
    QUERY_DIR=/queries   # DO NOT CHANGE THIS unless you really know what you're doing
    QUEUE_DIR=/data/queue  # DO NOT CHANGE THIS unless you really know what you're doing
    RESULTS_DIR=/data/results  # DO NOT CHANGE THIS unless you really know what you're doing
    AUTH_TOKEN=YesItsMe
    ALLOWED_INTERNAL_IPS=172.31.0.1,127.0.0.1,::1,192.168.1.100   # CHANGE 192.168.1.100 to the IP of Internal 
    METADATA_DIR=/metadata  # Don't change this unless you know what you're doing

`ALLOWED_INTERNAL_IPS` is a whitelist of IP addresses that are allowed to access the portions of the API that do not require authentication.  It should be VERY restrictive - maybe including localhost/127.0.0.1 only during testing

The `ENCRYPTION_KEY_HEX` must be shared with the external componenet, since all results are encrypted


### docker-compose

    services:
        external:
            image: markw/severance-external:0.0.1
            ports: ["3000:3000"]  # runs on 3000 internally
            env_file:
                - .env
            volumes:
                - "./data:/data"
                - "./queries-metadata:/metadata"
            environment:
                - RACK_ENV=production
                - APP_ENV=production     # both for redundancy

### Start 

`docker-compose up -d` and look for errors...

### Testing

#### alive?
`curl -v -H "Authorization: Bearer YesItsMe" http://localhost:3000/severance`

if you see an error, there is a problem!  Check what kind of error, and make sure that the auth key is what you expect as set in the `.env` file


#### Any known queries?
`curl -X GET http://localhost:3000/severance/available_queries   -H "Authorization: Bearer YesItsMe"   -H "Accept: application/json"`

returns JSON annotation of known queries (documentation pending!)

#### Submit a query request

```
curl -v -X POST http://localhost:3000/severance/queries   -H "Content-Type: application/json"   -H "Authorization: Bearer YesItsMe"   -d '{
    "query_id": "count",
    "bindings": {
      "orphanet_code": "http://www.orpha.net/ORDO/Orphanet_730"
    }
  }'
```

*response:*

```
HTTP/1.1 201 Created
Location:  http://localhost:3000/severance/jobs/ABC123
...
...
```

#### Check submitted query status

`curl -X GET http://localhost:3000/severance/jobs/ABC123   -H "Authorization: Bearer YesItsMe"   -H "Accept: application/json"`

*response:*

```
...
HTTP/1.1 201 Created...
Location:  http://localhost:3000/severance/jobs/ABC123
retry-after: 10
...
{"status": "processing"}
```

##  NOW START INTERNAL

The internal component will immediately ask the External component if it has any queries.

Your query just submitted will be picked-up and answered (assuming that Internal is functional!)

#### Check submitted query status

`curl -X GET http://localhost:3000/severance/jobs/ABC123   -H "Authorization: Bearer YesItsMe"   -H "Accept: application/json"`

*response:*

```
HTTP/1.1 200 OK
Content-type:  text/csv
...
...
count
123
```
## More tips coming soon!
