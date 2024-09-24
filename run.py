
from datetime import datetime
import requests
import traceback
import json
import time
import argparse
from aws_ingest import aws_ingest
import os


# Base URL of the API
BASE_URL = "http://127.0.0.1:7860"

def load_deforum_settings(file_path):
    with open(file_path, "r") as file:
        deforum_settings = json.load(file)
    return deforum_settings

# Function to create a batch of jobs
def create_batch(deforum_settings, settings_overrides=None):
    url = f"{BASE_URL}/deforum_api/batches"
    payload = {
        "deforum_settings": deforum_settings,
        "options_overrides": settings_overrides or {}
    }
    if settings_overrides:
        payload["settings_overrides"] = settings_overrides

    #response = requests.post(url, json=payload)
    response = requests.post(url, json=payload)
    return response.json()

# Function to get the list of batches
def get_batches():
    url = f"{BASE_URL}/deforum_api/batches"
    response = requests.get(url)
    return response.json()

# Function to get the list of jobs
def get_jobs():
    url = f"{BASE_URL}/deforum_api/jobs"
    response = requests.get(url)
    return response.json()

# Function to get the status of a specific job
def get_job_status(job_id):
    url = f"{BASE_URL}/deforum_api/jobs/{job_id}"
    response = requests.get(url)
    return response.json()

# Function to delete a specific job
def delete_job(job_id):
    url = f"{BASE_URL}/deforum_api/jobs/{job_id}"
    response = requests.delete(url)
    return response.json()

def is_api_running():
    url = f"{BASE_URL}/deforum_api/batches"
    try:
        response = requests.get(url)
        if response.status_code == 200:
            return True
        else:
            return False, response.status_code
    except requests.exceptions.RequestException as e:
        return False




def attempt_create_batch_with_retries(deforum_settings, retries=10, backoff_factor=15):
    for attempt in range(retries):
        try:
            response = create_batch(deforum_settings)
            print('Created Batch Response.')
            return response
        except Exception as e:
            print(f'Error occurred on attempt {attempt + 1}/{retries}: {e}')
            print(f'Error occurred on attempt {attempt + 1}/{retries}: {e}')
            print(traceback.format_exc())
            if attempt < retries - 1:
                sleep_time = backoff_factor 
                print(f'Waiting for {sleep_time} seconds before next attempt...')
                time.sleep(sleep_time)
            else:
                print(f'Failed to create batch after {retries} attempts.')
                return None


if __name__ == "__main__":
   

    
    start_time = datetime.now()
    start_process_time = time.time()
    
    current_dir =  os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="Music Video Generation")
    parser.add_argument(
        "--project_id",
        type=str,
        default="850b5eb8-9dbf-4ce2-add4-a5087d4d8e86",
        help="Name of the S3 bucket where audio and submitted form are stored"
    )
    parser.add_argument(
        "--s3_bucket_name",
        type=str,
        default="blob.api.app.ontoworks.org",
        help="Name of the S3 bucket where audio and submitted form are stored"
    )
    parser.add_argument(
        "--project_name",
        type=str,
        default="Project",
        help="name of the video file that the user can download"
    )
    args = parser.parse_args()

    #Project-specific API URL
    update_api_url = f"https://api.app.ontoworks.org/project/{args.project_id}/status"
    #Object key of the audio file stored in S3 bucket
    audio_object_key=f"Project.Audio/{args.project_id}"
    #Object key of the deforum settings stored in S3 bucket
    deforum_settings_object_key=f"Project.Finalized.Settings/{args.project_id}"
    #Path on EC2 where audio is downloaded to
    local_audio_path = os.path.join(current_dir, "data\\audio.mp3")
    #Path on EC2 where deforum settings is downloaded to
    local_settings_path = os.path.join(current_dir,"data\\deforum.json")
    #Path where video will be uploaded.
    upload_video_path  = f"Project.Output/{args.project_id}"
 


    aws_api = aws_ingest( "api@ontoworks.org" , "Ontoworks@123",update_api_url)

    aws_api.download_file_from_s3(args.s3_bucket_name, audio_object_key,local_audio_path)
    aws_api.download_file_from_s3(args.s3_bucket_name, deforum_settings_object_key, local_settings_path)

    video_file_name= args.project_name + ".mp4" #"_" + combined_form['batch_name'][8:] +'.mp4'

   

    deforum_settings = load_deforum_settings(local_settings_path)
    deforum_settings["soundtrack_path"] = local_audio_path

    max_frames  = deforum_settings["max_frames"]
    # Create a batch of jobs
    response = attempt_create_batch_with_retries(deforum_settings)
    print("Create Batch Response:" + str( json.dumps(response, indent=2)))
    
    print('Created Batch Response.')
    
    job_id = response["job_ids"][0]
    estimated_total_time = max_frames * 5
    try:
        response = get_job_status(job_id)

        while not (response["phase"]=="DONE"):
            if (response["status"]=="FAILED"):
                print("Automatic1111 Error")
                status_id = "37d6782f-1c3b-46d5-9378-ff85814bc60d"  # Assuming "Failed"
                update_response = aws_api.update_project_status(  video_file_name, error_message="Automatic1111 Error", success=False)
                print("Project status updated with failure: Automatic1111 Error" + ' \n Project status updated with failure.')
                
            time.sleep(5)
            print("Getting Status for job "+ str(  job_id))
            print('Getting Status for job ' + str(job_id))
            response = get_job_status(job_id)
            print("Full Job Status Response:", json.dumps(response, indent=2))
            current_process_time = time.time() - start_process_time
            
            phase_progress = float(current_process_time) / estimated_total_time


            awsUpdateResp = aws_api.update_project_percentage(int(phase_progress * 100))            
            print("AWS: "+ str( awsUpdateResp) + "" +"\n status: "+ str(  response["status"]) + "\n phase: " + str( response["phase"])  +'\n phase_progress: ' + str(int(phase_progress * 100)))
    
    except Exception as e:

        print(f"An error occurred: {e}")
        error_message = str(e)
        api_url = args.api_url
        status_id = "37d6782f-1c3b-46d5-9378-ff85814bc60d"  # Assuming "Failed"
        update_response = aws_api.update_project_status(  video_file_name, error_message=error_message, success=False)
        print("Project status updated with failure:" + str( update_response) + ' \n Project status updated with failure.')


    folder_path = f"./data/outputs/img2img-images/{deforum_settings['batch_name']}"
    bucket_path = args.s3_bucket_name
    msg = aws_api.upload_video_and_cleanup_frames(bucket_path, folder_path, video_file_name, args.video_path)
    print("project completed.")
    print('project completed.')

    if msg is not None:
        update_response = aws_api.update_project_status( video_file_name)
        print(update_response) 
        print(str(update_response))
    else:
        #FAILED
        update_response = aws_api.update_project_status( video_file_name,error_message="upload of finished video failed :(", success=False)
        print("Project status updated with failure:"+ str(  update_response))
        print('Project status updated with failure.')
    
    current_time = datetime.now()
    print("PROJECT FINISHED AT"+ str(  current_time))
    duration = current_time - start_time
    formatted_duration = str(duration).split(".")[0]  # This strips the microseconds part
    print(f"TOTAL DURATION: {formatted_duration}")



