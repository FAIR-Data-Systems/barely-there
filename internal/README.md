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

1. **Start with an empty folder**, and (as you, not as root) create a subfolder `./queries`
2. Make a copy of the env_template file to and edit it 
3. save it as `.env`
4. create a docker-compose.yml as instructed below 

### env_template

    # must be the same key as the External component!
    ENCRYPTION_KEY_HEX=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    RESULT_FORMAT=csv  # must be the same as the External component!
    QUERY_DIR=/queries  # DO NOT CHANGE THIS unless you really know what you're doing
    EXTERNAL_URL=http://111.111.111.111:3000   # The URL to the External API.  
    TRIPLESTORE_URL=http://localhost:7200/repositories/MyREPO  # make sure you create the readonly user
    TRIPLESTORE_USER = markw
    TRIPLESTORE_PASS = markw
    POLL_INTERVAL=10  # seconds
    UID=1000   #  at terminal:   id -u
    GID=1000   # at terminal:  id -g

The `ENCRYPTION_KEY_HEX` must be shared with the external componenet, since all results are encrypted

write this to `.env` after editing.  UID and GID ensure that you have access to modify the `./queries` folder.

Test your access to the external URL by calling, e.g. `http://111.111.111.111:3000/severance`  You will either get a message or an "Unauthorized" response.  Any other kind of error means you cannot see the server from here.

### docker-compose.yml

    services:
    internal:
        network_mode: host
        volumes:
        - "./queries:/queries"
        tmpfs:
        - /tmp:size=64m,noexec,nosuid,nodev
        environment:
        - TMPDIR=/tmp
        - UID=${UID:-1000}   # see .env file for how to set this
        - GID=${GID:-1000}
        image: markw/severance-internal:0.1.0
        env_file: .env
        user: "${UID:-1000}:${GID:-1000}"   # Run container as your host user, or 1000 fallback (which is usually the first non-root user created on a Linux system)  
        

The setting `network mode: host` is critical!  The internal code inside of the docker container must be able to "see" the external component, just as you did when you tested it in the last step.

### Start 

**You should not start Internal until you have installed and tested External**.  You will need to do some testing on External that will be interrupted by the polling from Internal.

`docker-compose up -d`


## QUERIES

In the `./queries` folder there are some examples of annotated queries that can be interpreted by Severance Internal.  If you modify these, your changes will be preserved from one compose-down/up to another.  If you need to fully reset, delete the content of the `./queries` folder and it will be re-populated with the example queries present in the image.

We provide some [guidance for how to author these queries](./queries/README.md) so that they can be interpreted by Severance and used to build a sensible UI on the External side, and also to help them be more universally discoverable based on their Query Type.

**Note:**  The ./queries folder content is re-read every time Internal polls External, so you can dynamically change the queries in that folder and it will update on the next polling cycle.


