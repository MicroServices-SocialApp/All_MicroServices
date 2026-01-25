import uuid
import random
from locust import HttpUser, task, between

class MicroservicesUser(HttpUser):
    # Simulated "thinking time" between actions (1-3 seconds)
    wait_time = between(1, 3)
    
    def on_start(self):
        """
        Executed when a simulated user is 'born'. 
        We create a user and log in to get a token.
        """
        self.username = f"user_{uuid.uuid4().hex[:8]}"
        self.password = "password123"
        self.token = None
        self.user_id = None

        # 1. Create the user via the User Service (routed through Ingress)
        self.client.post("/user/create", json={
            "username": self.username,
            "email": f"{self.username}@example.com",
            "password": self.password
        })

        # 2. Login via the Auth Service to get JWT
        # Note: Your Auth service uses OAuth2PasswordRequestForm (form-data)
        login_data = {
            "username": self.username,
            "password": self.password
        }
        
        with self.client.post("/auth/login", data=login_data, catch_response=True) as response:
            if response.status_code == 200:
                self.token = response.json().get("access_token")
                self.headers = {"Authorization": f"Bearer {self.token}"}
            else:
                response.failure(f"Failed to login: {response.text}")

    @task(4)
    def view_posts(self):
        """Reads all posts. Most common action (Weight: 5)"""
        self.client.get("/post/read_all_posts?limit=10")

    @task(4)
    def view_comments(self):
        """Reads all posts. Most common action (Weight: 5)"""
        self.client.get("/comment/read_all")

    @task(2)
    def create_post_and_comment(self):
        """Creates a post, then creates a comment on it. (Weight: 2)"""
        if not self.token:
            return

        # Create Post
        post_content = {"text": f"Stress test post from {self.username}"}
        post_res = self.client.post("/post/create", json=post_content, headers=self.headers)
        
        if post_res.status_code == 201:
            post_id = post_res.json().get("id")
            
            # Create Comment on that post
            comment_content = {
                "text": "This is a stress test comment",
                "post_id": post_id
            }
            self.client.post("/comment/create", json=comment_content, headers=self.headers)

    # @task(1)
    # def check_users(self):
    #     """Reads all users. (Weight: 1)"""
    #     self.client.get("/user/read_all_users")