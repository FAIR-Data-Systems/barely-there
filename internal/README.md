<img src="../docs/SeverenceSMW.png"/>

# Severance: Secure SPARQL Service

# Installing the Internal Component

## Prerequisites

1. A GraphDB instance up and running, containing...
2. A repository (called e.g. 'severance'), containing...
3. Patient Registry data following the CARE-SM model
4. A read-only user on the 'severance' repository (e.g. username/pass 'suser'/'spass')
5. An instance of Severence External running in your DMZ, and
6. It's API URL must be visible from THIS SERVER to reach-out

## Configuration

1. Make a copy of the env_template file and edit it 
2. save it as .env in the same folder as the docker-compose file

### env_template

    ENCRYPTION_KEY_HEX=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    RESULT_FORMAT=csv  # must be the same as the External component!
    QUERY_DIR=/queries  # DO NOT CHANGE THIS unless you really know what you're doing
    EXTERNAL_URL=http://111.111.111.111:3000   # The URL to the External API.  
    TRIPLESTORE_URL=http://localhost:7200/repositories/MyREPO  # make sure you create the readonly user
    TRIPLESTORE_USER = markw
    TRIPLESTORE_PASS = markw
    POLL_INTERVAL=10                    # seconds

The `ENCRYPTION_KEY_HEX` must be shared with the external componenet, since all results are encrypted

Test your access to the external URL by calling, e.g. `http://111.111.111.111:3000/severance`  You will either get a message or an "Unauthorized" response.  Any other kind of error means you cannot see the server from here.

### docker-compose

    services:
        internal:
            network_mode: host
            image: markw/severance-internal:0.0.1
            env_file: .env


The setting `network mode: host` is critical!  The internal code inside of the docker container must be able to "see" the external component, just as you did when you tested it in the last step.

### Start 

**You should not start Internal until you have installed and tested External**.  You will need to do some testing on External that will be interrupted by the polling from Internal.

`docker-compose up -d`


## QUERIES

In the ./queries folder there are some examples of annotated queries that can be interpreted by Severance Internal.

We provide some [guidance for how to author these queries](./queries/README.md) so that they can be interpreted by Severance and used to build a sensible UI on the External side, and also to help them be more universally discoverable based on their Query Type.

**Note:**  The ./queries folder content is read at start-up of the Internal component.  If you modify the queries, you will want to restart this service by docker-compose down/up.


