<img src="../../docs/SeverenceSMW.png"/>

# Severance: Queries

## This folder is non-normative

This folder is here only to **contain demonstration queries**, and to make it immediateluy available in the docker container using the default docker-compose.

## The Queries Folder

1. Contains queries - one per file
2. Queries follow the [GRLC annotation format](https://github.com/CLARIAH/grlc?tab=readme-ov-file#decorator-syntax) to annotate the query, plus a few extra fields used specifically by Severance.
3. query filenames need to be a single string of characters (using _ or - is fine for multi-word names), followed by the .rq extension
4. The content of this folder should be replaced by your own content. An example, where the objective was to enhance interoperability, is shown in the [Duchenne Shared Queries folder](https://github.com/World-Duchenne-Organization/shared-queries).  That folder is openly available to all participants to ensure that queries are identical from participant-to-participant.  (of course, the folder you mount inside of the Docker container is NOT OPEN!)

## New tags:

1. query_id: REQUIRED - this is the local identifier of the query.  It should match the filename (without the .rq extension)
2. query_version: OPTIONAL - a freetext field using whatever versioning system you wish, to indicate which version of the query this content represents
3. Query_type:  OPTIONAL - A URL to an ontology term that categorizes the query to a specific type.  We recommend that this Class be a subclass of [http://edamontology.org/operation_3438](EDAM Calculation - http://edamontology.org/operation_3438)
