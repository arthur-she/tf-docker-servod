# Servod Docker image

[TOC]

## Building

To build the image, run the following commands

    cd <PATH TO XOLABS-COMMON-CORE>/src/dockerfiles/
    docker build -t <gcloud-registry>/servod:latest ./servod

Push the image to gcloud registry to be pulled and used by Docker Host Box.

    docker push <gcloud-registry>/servod:latest

## Running

First create a file to store environment variables for the servod instance. For example,

    localhost ~ # cat host2_env
    PORT=9999
    MODEL=kevin
    BOARD=kevin
    SERIAL=C1903144845

Then run the container with the above variables,

    docker run -d \
        --network host \
        --name servod \
        --env-file host2_env \
        --cap-add=NET_ADMIN \
        --volume=/dev:/dev \
        --privileged \
        <servod image> \
        /start_servod.sh


## Sending command to DUT to confirm access

Example:

    docker exec -d servod 'dut-control -p $PORT power_state:off'


# Turn down servod container

    # Close port 9999 of the host.
    docker exec -d servod /stop_servod.sh
    docker stop servod