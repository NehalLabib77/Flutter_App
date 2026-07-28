"""Shared Flask extensions.

We keep them in one module so the application factory and the models
import the exact same instances.
"""

from flask_cors import CORS
from flask_jwt_extended import JWTManager
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()
jwt = JWTManager()
cors = CORS()

__all__ = ["db", "jwt", "cors"]